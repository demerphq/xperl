package XPerl::Task;

use v5.40;
use feature 'async';
no warnings 'experimental::builtin';
use builtin qw(blessed refaddr weaken);

our $VERSION = '0.01';
our $SCHEDULER;

sub _register ($task) {
    if ($SCHEDULER) {
        _enqueue($task);
    }
    return $task;
}

sub _new ($fiber, $args) {
    return _register(bless {
        state => 0, fiber => $fiber, args => $args, waiters => [],
    }, __PACKAGE__);
}

sub resolved ($class, $value = undef) {
    return bless {state => 2, value => $value, waiters => []}, $class;
}

sub rejected ($class, $error) {
    die 'A rejected task requires an exception' unless defined $error;
    return bless {state => 3, error => $error, waiters => []}, $class;
}

sub delay ($class, $seconds) {
    die 'A task delay must be nonnegative' unless defined $seconds && $seconds >= 0;
    return _register(bless {
        state => 0, deadline => _now() + $seconds, waiters => [],
    }, $class);
}

sub _now () {
    state $clock = do {
        local $@;
        local ${^ERROR_OBJ};
        require Time::HiRes;
        my $id = eval { Time::HiRes::CLOCK_MONOTONIC() };
        defined $id && eval { Time::HiRes::clock_gettime($id) >= 0 }
            ? sub { Time::HiRes::clock_gettime($id) }
            : \&Time::HiRes::time;
    };
    return $clock->();
}

sub state ($self) { return (qw(pending waiting completed failed))[$self->{state}] }
sub running ($self) { return !!$self->{running} }
sub completed ($self) { return $self->{state} == 2 }
sub failed ($self) { return $self->{state} == 3 }
sub result ($self) {
    die $self->{error} if $self->{state} == 3;
    die 'Task has not completed' unless $self->{state} == 2;
    return $self->{value};
}

sub CLONE_SKIP { return 1 }
sub CLONE { undef $SCHEDULER }

sub _enqueue ($task) {
    return if $SCHEDULER->{closing};
    return if $task->{state} >= 2 || $task->{queued};
    $SCHEDULER->{tasks}{refaddr($task)} = $task;
    if (exists $task->{deadline}) {
        $SCHEDULER->{timers}{refaddr($task)} = $task;
        return;
    }
    return if $task->{state} == 1;
    $task->{queued} = 1;
    push @{$SCHEDULER->{ready}}, $task;
}

sub _wake ($task) {
    for my $waiter (@{delete $task->{waiters} // []}) {
        next unless $waiter && $waiter->{state} == 1
            && $waiter->{dependency} == $task;
        delete $waiter->{dependency};
        if ($task->{state} == 3) {
            $waiter->{resume_error} = $task->{error};
        }
        else {
            $waiter->{resume_value} = $task->{value};
        }
        $waiter->{state} = 0;
        _enqueue($waiter);
    }
}

sub _finish ($task, $state, $value) {
    $task->{state} = $state;
    $task->{$state == 2 ? 'value' : 'error'} = $value;
    delete $task->{dependency};
    delete $task->{args};
    delete $task->{fiber};
    _wake($task);
    if ($SCHEDULER) {
        delete $SCHEDULER->{tasks}{refaddr($task)};
        delete $SCHEDULER->{timers}{refaddr($task)};
    }
}

sub cancel ($self, $error = undef) {
    return if $self->{state} >= 2;
    die 'Cannot cancel a running task' if $self->{running};
    return if $self->{closing};
    local $self->{closing} = 1;
    local $@;
    local ${^ERROR_OBJ};
    $error //= bless {}, 'XPerl::Task::Cancelled';
    my $fiber = delete $self->{fiber};
    my $ok = eval { _close($fiber) if $fiber; 1 };
    my $failure = $ok ? undef : (${^ERROR_OBJ} // $@);
    _finish($self, 3, $failure // $error);
    die $failure unless $ok;
}

sub _wait ($task, $dependency) {
    my $cursor = $dependency;
    while ($cursor) {
        die 'Circular task dependency' if $cursor == $task;
        $cursor = $cursor->{dependency};
    }
    $task->{state} = 1;
    $task->{dependency} = $dependency;
    push @{$dependency->{waiters}}, $task;
    weaken($dependency->{waiters}[-1]);
    if ($dependency->{state} >= 2) {
        _wake($dependency);
    }
    else {
        _enqueue($dependency);
    }
}

sub _drive ($task) {
    return if $task->{state} >= 2;
    $task->{queued} = 0;
    my $packet;
    local $@;
    local ${^ERROR_OBJ};
    local $task->{running} = 1;
    my $ok = eval {
        my $args = delete $task->{args} // [delete $task->{resume_value}];
        $packet = _step($task->{fiber}, $args, delete $task->{resume_error}, undef);
        if ($packet->[0] == 0) {
            _finish($task, 2, $packet->[1]);
        }
        elsif ($packet->[0] == 2) {
            _wait($task, $packet->[1]);
        }
        else {
            die 'An async task cannot yield generator values';
        }
        1;
    };
    _finish($task, 3, ${^ERROR_OBJ} // $@) unless $ok;
}

sub _poll_timers () {
    return unless keys %{$SCHEDULER->{timers}};
    my $now = _now();
    for my $id (keys %{$SCHEDULER->{timers}}) {
        my $task = $SCHEDULER->{timers}{$id};
        if ($task->{state} >= 2) {
            delete $SCHEDULER->{timers}{$id};
        }
        elsif ($task->{deadline} <= $now) {
            delete $SCHEDULER->{timers}{$id};
            _finish($task, 2, undef);
        }
    }
}

sub _run ($root) {
    die 'run requires an XPerl::Task' unless blessed($root) && $root->isa(__PACKAGE__);
    die 'run cannot be nested' if $SCHEDULER;
    return $root->result if $root->{state} >= 2;
    local $@;
    local ${^ERROR_OBJ};
    local $SCHEDULER = {ready => [], tasks => {}, timers => {}};
    _enqueue($root);
    my $ok = eval {
        while ($root->{state} < 2) {
            _poll_timers();
            if (my $task = shift @{$SCHEDULER->{ready}}) {
                _drive($task);
            }
            elsif (keys %{$SCHEDULER->{timers}}) {
                my $next;
                for my $task (values %{$SCHEDULER->{timers}}) {
                    $next = $task->{deadline}
                        if !defined $next || $task->{deadline} < $next;
                }
                my $delay = $next - _now();
                Time::HiRes::sleep($delay) if $delay > 0;
            }
            elsif ($root->{state} < 2) {
                die 'No runnable task can complete this run';
            }
        }
        1;
    };
    my $error = !$ok ? (${^ERROR_OBJ} // $@)
        : $root->{state} == 3 ? $root->{error} : undef;
    # The default driver owns tasks it starts. Unfinished tasks unwind when
    # the root finishes, rather than retaining an abandoned execution stack.
    my $cleanup_failure;
    $SCHEDULER->{closing} = 1;
    for my $task (values %{$SCHEDULER->{tasks}}) {
        next if $task->{state} >= 2;
        my $cleaned = eval { $task->cancel; 1 };
        $cleanup_failure //= ${^ERROR_OBJ} // $@ unless $cleaned;
    }
    die $error if defined $error;
    die $cleanup_failure if defined $cleanup_failure;
    return $root->result;
}

sub next_value ($generator) {
    local $@;
    local ${^ERROR_OBJ};
    my ($args, $error) = ([], undef);
    my $lease = _claim($generator);
    $args = undef;
    while (1) {
        my $packet = _step($generator, $args, $error, $lease);
        return $packet->[1] unless $packet->[0] == 2;
        my $value;
        my $ok = eval { $value = await $packet->[1]; 1 };
        $error = $ok ? undef : (${^ERROR_OBJ} // $@);
        $args = [$value];
    }
}

package XPerl::Task::Cancelled;
use overload '""' => sub { "Task cancelled\n" }, fallback => 1;

1;

=head1 NAME

XPerl::Task - experimental cooperative async executions

=head1 SYNOPSIS

    use async;
    no warnings 'experimental::builtin';

    async sub fetch ($id) {
        await XPerl::Task->delay(0.01);
        return "user $id";
    }

    async sub main () {
        my $a = fetch(1);
        my $b = fetch(2);
        return [await $a, await $b];
    }

    my $users = run(main());

=head1 EXECUTION

An async call returns a task object. Its body runs in scalar context when
driven, with its own Perl call stack. C<await> returns a completed task's
value or raises its exception. If the task is unfinished, it suspends the
current execution. Ordinary nested Perl helpers may await without being
declared async themselves.

The call retains argument aliases. A signature binds its parameters when
the task starts. Lexical variables, closure bindings and supported dynamic
localizations survive suspension. See L<perlgenerator> for localization
restrictions. An unsupported active localization rejects the wait before
registering a dependency. The execution can catch that exception and retry
after leaving the offending scope.

Each task starts with undefined regex captures. Later matches and their
captures survive suspension independently of other tasks. An empty pattern
uses that task's previous match, rather than its caller's. The regex
restrictions described in L<perlgenerator> apply to unfinished awaits too.

This is a prototype, not a stable public API. Task fields and the private
execution methods are implementation details. There is no parallel Perl
execution within a driver and no scheduling check in ordinary opcode
dispatch.

Named recursive calls create tasks normally. C<__SUB__> currently refers to
the underlying Perl body, so invoking it bypasses task creation. Recursive
async code must use its declared name in this prototype.

C<my async sub> and C<state async sub> follow the usual lexical-sub scope
and closure rules. Calling either returns a task. A C<my> declaration
creates a new lexical function each time execution reaches it, while a
C<state> declaration keeps its function and its state between calls.

    sub make_adder ($offset) {
        my async sub add ($value) {
            return $offset + $value;
        }
        return \&add;
    }

For named lexical recursion, forward-declare with C<my sub name;> before
the C<async sub name (...) { ... }> definition. Async declarations require
a body. Async methods are not supported by this prototype.

C<async multi sub> defines an asynchronous multisub. Every clause in the
group must use that spelling. Calling the multisub returns a task, and
argument dispatch happens when the task starts. Clause guards and bodies
can await. A no-match failure belongs to the task and reports the original
call location when propagated by C<run> or C<await>.

=head1 DEFAULT DRIVER

The built-in C<run($task)> drives its root and tasks scheduled within that
run. Ready tasks run in queue order until they await or finish. A task
created inside an active run joins its ready queue. Outside a run, a new
task stays unstarted until passed to C<run> or awaited by a running task.
Unrelated tasks created outside the run are left alone.

The driver returns the root's value or raises its exception. When the root
finishes, it cancels unfinished work belonging to that run. Cleanup-created
tasks remain unstarted and may be run later. Cleanup follows the generator
warning rules. An escaping exception is propagated after the other tasks
have unwound. The root's failure takes precedence over cleanup failures.

Nested calls to the default driver are rejected. A new interpreter starts
with a fresh driver. Tasks and their saved executions cannot be transferred
between interpreters.

The initial driver supports task dependencies and timers. It does not yet
provide asynchronous socket or file I/O. C<delay> uses Time::HiRes, so it
requires that extension. Timers use a monotonic clock when available, with
a wall-clock fallback. Other drivers can use the same private execution
operations; those operations are experimental too.

=head1 OPERATIONS

C<XPerl::Task-E<gt>resolved($value)> creates an available result.
C<XPerl::Task-E<gt>rejected($exception)> creates a failed result.
C<XPerl::Task-E<gt>delay($seconds)> creates a timer which completes with
undef. The delay must be nonnegative.

C<$task-E<gt>state> returns C<pending>, C<waiting>, C<completed> or
C<failed>. C<running> identifies execution inside the task's body.
C<completed> and C<failed> test terminal states. C<result> reads a completed
value, rethrows a failure, or raises an exception if the task is unfinished.

C<$task-E<gt>cancel> explicitly unwinds an unstarted or suspended task.
Scope cleanup runs with that execution's bindings installed. Its waiters
receive an C<XPerl::Task::Cancelled> exception, or an optional exception
passed to C<cancel>. Cancellation is terminal, even if cleanup reports an
error. Repeating it on a terminal task has no effect. A running task cannot
be cancelled by this operation.

=head1 GENERATORS

C<XPerl::Task::next_value($generator)> drives a generator until its next
ordinary yield or completion. An await inside the generator suspends its
outer task through this adapter. The child execution returns to the adapter
before the outer execution suspends, so no native resume frame is retained.

The adapter owns an exclusive claim across each call, including any waits.
Competing adapters and raw generator calls are rejected while that claim is
active. Exceptions and cancellation release it. A replacement adapter can
continue waiting for the saved dependency. Ordinary generator invocation
and C<iter> do not automatically relay waits in this prototype.

=head1 NATIVE BOUNDARIES

The saved execution contains Perl frames, not native C frames. An unresolved
await inside an XS, sort, regex or similar native callback is rejected.
Awaiting an already available result there is permitted because it does not
suspend. The owning execution loop enforces this distinction even when a
callback uses the same Perl stack.

Ordinary C<eval BLOCK> can span a wait. C<eval STRING> currently retains
compiler save entries which are not isolated, so an unresolved wait there
is rejected by the localization guard.

=cut
