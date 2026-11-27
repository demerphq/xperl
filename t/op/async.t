#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('Time::HiRes');
    skip_all_without_dynamic_extension('B');
}

use strict;
use warnings;
use async;
use generator;
no warnings 'experimental::builtin';

async sub answer ($value) { return $value + 1 }
my $task = answer(41);
isa_ok($task, 'XPerl::Task');
is($task->state, 'pending', 'calling an async sub creates a pending task');
is(run($task), 42, 'run returns the task result');
ok($task->completed, 'task retains completed state');
is($task->result, 42, 'task retains its result');
is(run($task), 42, 'a completed task can be read again');

{
    my $offset = 10;
    my $code = async sub ($value) { return $offset + $value };
    is(run($code->(5)), 15, 'anonymous async subs retain closure bindings');
}

async sub compose ($value) { return 2 * await answer($value) }
is(run(compose(20)), 42, 'await receives a child task result');

async sub recursive_task ($depth) {
    return 0 unless $depth;
    return $depth + await recursive_task($depth - 1);
}
is(run(recursive_task(10)), 55, 'named async recursion retains independent body activations');

sub nested_leaf ($task, $depth) {
    my $before = "depth $depth";
    if ($depth) {
        return nested_leaf($task, $depth - 1) + 1;
    }
    my $value = await $task;
    is($before, 'depth 0', 'nested await retains lexical storage');
    like((caller(1))[3], qr/nested_leaf/, 'nested await retains caller frames');
    return $value;
}
async sub recurse () { return nested_leaf(answer(39), 2) }
is(run(recurse()), 42, 'ordinary recursive helpers may await');

{
    our $binding = 'caller';
    my @events;
    sub localized_leaf ($name, $events) {
        our $binding;
        local $binding = $name;
        push @$events, "start $binding";
        await XPerl::Task->delay(0);
        push @$events, "end $binding";
        return $binding;
    }
    async sub localized_task ($name, $events) { return localized_leaf($name, $events) }
    async sub both ($events) {
        my $a = localized_task('A', $events);
        my $b = localized_task('B', $events);
        return [await $a, await $b];
    }
    my $values = run(both(\@events));
    is("@$values", 'A B', 'shared ordinary sub has independent activations');
    is("@events", 'start A start B end A end B', 'ready tasks interleave cooperatively');
    is($binding, 'caller', 'caller package binding survives both tasks');
}

async sub failing () {
    await XPerl::Task->delay(0);
    die "task failed\n";
}
async sub recover () {
    my $ok = eval { await failing(); 1 };
    like($@, qr/task failed/, 'await raises a child failure at its suspension point');
    ok(!$ok, 'the surrounding eval catches the failure');
    await XPerl::Task->delay(0);
    return 'recovered';
}
is(run(recover()), 'recovered', 'a caught task failure permits further awaits');

{
    my $failed = failing();
    my $ok = eval { run($failed); 1 };
    ok(!$ok, 'uncaught task failure reaches run caller');
    like($@, qr/task failed/, 'run preserves the task exception');
    ok($failed->failed, 'failed task retains terminal state');
}

{
    my $ready = XPerl::Task->resolved(17);
    is(await $ready, 17, 'ready results do not require a suspension owner');
    my $ok = eval { await XPerl::Task->delay(0); 1 };
    ok(!$ok, 'an unresolved await requires an owning loop');
    like($@, qr/owning Perl execution loop/, 'missing owner has a clear diagnostic');
}

{
    my $g = gen {
        my $value = await answer(5);
        yield $value;
        my $next = await answer(8);
        yield $next;
    };
    async sub consume ($g) {
        my $a = XPerl::Task::next_value($g);
        my $b = XPerl::Task::next_value($g);
        return "$a $b";
    }
    is(run(consume($g)), '6 9', 'generator adapter relays waits through its task');
    undef $g;
}

{
    my $g = gen { yield await answer(2) };
    my $ok = eval { my $value = $g->(); 1 };
    ok(!$ok, 'raw generator call cannot relay an unresolved wait');
    like($@, qr/owning Perl execution loop/, 'raw generator wait reports its suspension barrier');
}

{
    async sub unsafe_local () {
        my %values = (key => 'outside');
        my $caught;
        {
            local $values{key} = 'inside';
            eval { await answer(2) };
            $caught = $@;
            is($values{key}, 'inside', 'rejected await retains the active local');
        }
        like($caught, qr/unsupported localization/, 'await uses localization preflight');
        is($values{key}, 'outside', 'unsupported scope exits normally');
        return await answer(5);
    }
    is(run(unsafe_local()), 6, 'caught rejection permits a later supported wait');
}

{
    async sub native_sort () {
        my @sorted = sort {
            await XPerl::Task->delay(0);
            $a <=> $b;
        } (2, 1);
        return "@sorted";
    }
    my $ok = eval { run(native_sort()); 1 };
    ok(!$ok, 'sort callback cannot suspend its native caller');
    like($@, qr/owning Perl execution loop/, 'sort callback reports its suspension barrier');

    async sub ready_sort () {
        my @sorted = sort {
            await XPerl::Task->resolved(1);
            $a <=> $b;
        } (2, 1);
        return "@sorted";
    }
    is(run(ready_sort()), '1 2', 'native callback may await an available result');
}

{
    my $task;
    async sub self_cancel () {
        my $ok = eval { $task->cancel; 1 };
        ok(!$ok, 'a running task cannot be closed');
        return await answer(8);
    }
    $task = self_cancel();
    is(run($task), 9, 'rejected reentrant close leaves the task usable');
}

{
    my $task = answer(1);
    $task->cancel;
    $task->cancel;
    ok($task->failed, 'cancellation before first execution is idempotent');
    my $ok = eval { run($task); 1 };
    ok(!$ok, 'cancelled task cannot resume');
    like($@, qr/Task cancelled/, 'cancellation has a distinct exception');
}

{
    use feature 'defer';
    no warnings 'experimental::defer';
    my $cleaned = 0;
    my $waiter;
    my $work = async sub () {
        defer { ++$cleaned }
        await XPerl::Task->delay(10);
        return 'unexpected';
    };
    my $stop = async sub () {
        $waiter->cancel;
        return 'stopped';
    };
    my $root = async sub () {
        $waiter = $work->();
        my $stopper = $stop->();
        my $ok = eval { await $waiter; 1 };
        ok(!$ok, 'cancellation wakes a waiting task with an exception');
        return await $stopper;
    };
    is(run($root->()), 'stopped', 'driver continues after cancellation');
    is($cleaned, 1, 'cancellation unwinds the suspended scope once');
}

{
    async sub nested_driver () { return run(answer(2)) }
    my $ok = eval { run(nested_driver()); 1 };
    ok(!$ok, 'the default driver rejects reentrant run');
    like($@, qr/run cannot be nested/, 'reentrant run explains its restriction');
}

{
    my $one = answer(1);
    my $two = answer(2);
    is(run($one), 2, 'run drives its requested root');
    is($two->state, 'pending', 'run leaves an unrelated outside task alone');
    is(run($two), 3, 'an unrelated task remains runnable');
}

{
    async sub alias_arguments {
        ++$_[0];
        await XPerl::Task->delay(0);
        return ++$_[0];
    }
    my $value = 10;
    is(run(alias_arguments($value)), 12, 'task arguments retain their aliases');
    is($value, 12, 'argument writes reach the original scalar');
}

{
    async sub later () { await XPerl::Task->delay(0); return 99 }
    async sub take_one ($generator) { return XPerl::Task::next_value($generator) }
    my $g = gen {
        my $value = await later();
        yield $value;
        yield 'second';
    };
    my $root = async sub () {
        my $first = take_one($g);
        my $second = take_one($g);
        my $value = await $first;
        my $ok = eval { await $second; 1 };
        ok(!$ok, 'a competing generator adapter is rejected');
        like($@, qr/active async adapter/, 'competing consumer has a clear diagnostic');
        is(XPerl::Task::next_value($g), 'second', 'normal yield releases the adapter claim');
        return $value;
    };
    is(run($root->()), 99, 'competing consumers cannot invent an await result');
}

{
    my ($consumer, $stopper);
    my $g = gen { my $value = await later(); yield $value };
    my $stop = async sub () { $consumer->cancel; return 'cancelled' };
    my $root = async sub () {
        $consumer = take_one($g);
        $stopper = $stop->();
        await $stopper;
        my $ok = eval { my $value = $g->(); 1 };
        ok(!$ok, 'raw invocation cannot resume an abandoned await');
        return XPerl::Task::next_value($g);
    };
    is(run($root->()), 99, 'replacement adapter waits for the original dependency');
}

{
    my $g = gen { return 7 };
    is(XPerl::Task::next_value($g), 7, 'adapter returns final generator value');
    for (1 .. 10) {
        is(XPerl::Task::next_value($g), undef, 'exhausted generator stays exhausted');
    }
}

{
    our $phase_ran = 0;
    for my $name (qw(BEGIN UNITCHECK CHECK INIT END Example::BEGIN Example::END)) {
        my $ok = eval "async sub $name () { \$main::phase_ran++ }; 1";
        ok(!$ok, "async $name is rejected before installing a phase body");
    }
    is($phase_ran, 0, 'rejected async phase bodies never execute');
    my $ok = eval 'async sub forward_only; 1';
    ok(!$ok, 'an async declaration requires a body');
}

{
    my $prototype = eval q{
        no feature 'signatures';
        async sub prototype_task($) { return $_[0] + 1 }
        prototype(\&prototype_task);
    };
    is($@, '', 'traditional async declaration compiles');
    is($prototype, '$', 'named async factory preserves its prototype');
    is(run(prototype_task(41)), 42, 'traditional async body receives arguments');
    my $constant = eval q{
        no feature 'signatures';
        async sub constant_task () { 42 }
        constant_task();
    };
    is($@, '', 'traditional constant-shaped async body compiles');
    isa_ok($constant, 'XPerl::Task');
    is(run($constant), 42, 'constant-shaped body still creates a task');
    my $ok = eval q{
        $undeclared_async_test = 1;
        async sub after_error () { return 42 }
        1;
    };
    ok(!$ok, 'an earlier compile error does not install an invalid async factory');
    like($@, qr/requires explicit package name/, 'original compile diagnostic is preserved');
}

{
    require B::Deparse;
    my $deparse = B::Deparse->new;
    $deparse->ambient_pragmas_from_caller;
    my $text = $deparse->coderef2text(\&compose);
    like($text, qr/await/, 'deparser sees the body retained by the async factory');
    my $roundtrip = eval "async sub $text";
    is($@, '', 'deparsed async body compiles');
    is(run($roundtrip->(20)), 42, 'deparsed async body retains its behavior');
}

{
    my ($a, $b);
    my $left = async sub () { return await $b };
    my $right = async sub () { return await $a };
    $a = $left->();
    $b = $right->();
    my $ok = eval { run($a); 1 };
    ok(!$ok, 'circular task waits terminate with an exception');
    like($@, qr/Circular task dependency/, 'cycle diagnostic explains the dependency');
}

{
    use feature 'defer';
    no warnings 'experimental::defer';
    my $created;
    my $worker = async sub () {
        defer { $created = answer(30) }
        await XPerl::Task->delay(10);
    };
    my $root = async sub () {
        my $child = $worker->();
        await XPerl::Task->delay(0);
        return 'root';
    };
    is(run($root->()), 'root', 'root completion unwinds unfinished work');
    is($created->state, 'pending', 'cleanup-created task is not queued in a closing driver');
    is(run($created), 31, 'cleanup-created task can run in a later driver');
}

{
    async sub native_regex () {
        'a' =~ /a(?{ await XPerl::Task->delay(0) })/;
        return 1;
    }
    my $ok = eval { run(native_regex()); 1 };
    ok(!$ok, 'regex callback cannot suspend an active native match');
    like($@, qr/owning Perl execution loop/, 'regex callback reports the native barrier');

    async sub string_eval () {
        my $result = eval 'await answer(40)';
        die $@ if $@;
        return $result;
    }
    my $eval_ok = eval { run(string_eval()); 1 };
    ok(!$eval_ok, 'string eval cannot suspend with unsupported compiler saves');
    like($@, qr/unsupported localization/, 'string eval rejects before changing bindings');
}

{
    our $destroyed = 0;
    {
        package AsyncResultGuard;
        sub DESTROY { ++$main::destroyed }
    }
    async sub result_object () { return bless [], 'AsyncResultGuard' }
    async sub discard_results () {
        for (1 .. 20) {
            my $value = await result_object();
            undef $value;
            await XPerl::Task->delay(0);
        }
        return $destroyed;
    }
    is(run(discard_results()), 20, 'completed child results are released during a long run');
}

{
    our $dynamic = 'outside';
    sub interleaved_leaf ($id, $depth, $rounds) {
        local $dynamic = "$id:$depth";
        my $capture = sub { "$id:$depth" };
        my $identity = \$id;
        if ($depth) {
            my $error = interleaved_leaf($id, $depth - 1, $rounds);
            return $error if length $error;
        }
        else {
            for (1 .. $rounds) {
                await XPerl::Task->delay(0);
                return 'lexical alias changed' unless $$identity == $id;
                return 'closure changed' unless $capture->() eq "$id:$depth";
                return 'dynamic binding changed' unless $dynamic eq "$id:$depth";
            }
        }
        return $dynamic eq "$id:$depth" ? '' : 'outer binding changed';
    }
    async sub interleaved_worker ($id, $depth, $rounds) {
        return interleaved_leaf($id, $depth, $rounds);
    }
    async sub random_interleaving () {
        srand 12345;
        my @tasks = map { interleaved_worker($_, int(rand 5), 1 + int(rand 5)) } 1 .. 24;
        my @errors;
        for my $task (@tasks) {
            my $error = await $task;
            push @errors, $error if length $error;
        }
        return join ', ', @errors;
    }
    is(run(random_interleaving()), '', 'varied recursive interleavings retain activation identities');
    is($dynamic, 'outside', 'randomized workers restore the caller binding');
}

{
    my $original;
    {
        local $@;
        local ${^ERROR_OBJ};
        eval { die "original task error\n" };
        $original = ${^ERROR_OBJ};
    }
    async sub fail_with ($error) { await XPerl::Task->delay(0); die $error }
    async sub catch_identity ($error) {
        eval { await fail_with($error) };
        return ${^ERROR_OBJ};
    }
    my $caught = run(catch_identity($original));
    is(builtin::refaddr($caught), builtin::refaddr($original),
       'failed await preserves canonical exception identity');

    eval { die "caller error\n" };
    my ($text, $exception) = ($@, ${^ERROR_OBJ});
    my $value = run(answer(1));
    my ($after_text, $after_exception) = ($@, ${^ERROR_OBJ});
    is($value, 2, 'successful task returns with a prior caller exception');
    is($after_text, $text, 'successful driver preserves caller error text');
    is(builtin::refaddr($after_exception), builtin::refaddr($exception),
       'successful driver preserves the canonical caller exception');
}

{
    my $program = <<'PROG';
use async;
async sub example ($value) { return await XPerl::Task->resolved($value) }
PROG
    fresh_perl_like($program, qr/async sub example.*await/s,
                    {switches => ['-MO=Deparse']}, 'deparser emits named async declarations');
}

{
    my $program = <<'PROG';
use feature 'async';
use builtin qw(run refaddr);
no warnings 'experimental::builtin';
async sub cold_answer { return 42 }
eval { die "existing error\n" };
my ($text, $error) = ($@, ${^ERROR_OBJ});
my $task = cold_answer();
my $value = run($task);
die 'lost caller error' unless $@ eq $text && refaddr(${^ERROR_OBJ}) == refaddr($error);
print "$value\n";
PROG
    fresh_perl_is($program, "42\n", {}, 'cold driver loading preserves caller exception state');

    $program = <<'PROG';
use feature 'async';
async sub cold_answer { return 42 }
unshift @INC, sub { die "distinctive driver load failure\n" if $_[1] eq 'XPerl/Task.pm'; return };
my $ok = eval { cold_answer(); 1 };
die 'load unexpectedly succeeded' if $ok;
die "wrong failure: $@" unless $@ =~ /distinctive driver load failure/;
print 'caught';
PROG
    fresh_perl_is($program, 'caught', {}, 'factory preserves a cold driver load failure');

    $program =~ s/use feature 'async';/use feature 'async'; use builtin 'run'; no warnings 'experimental::builtin';/;
    $program =~ s/cold_answer\(\); 1/run(undef); 1/;
    fresh_perl_is($program, 'caught', {}, 'built-in run preserves a cold driver load failure');
}

{
    my $program = <<'PROG';
use async;
require Time::HiRes;
no warnings 'redefine';
local *Time::HiRes::clock_gettime = sub { -1 };
die 'failed clock selected' unless XPerl::Task::_now() > 0;
print 'fallback';
PROG
    fresh_perl_is($program, 'fallback', {}, 'failed monotonic clock probe selects the wall clock');
}

{
    use feature 'defer';
    no warnings 'experimental::defer';
    for my $fail_root (0, 1) {
        my ($length, $cleaned) = (2, 0);
        my $broken_cleanup = async sub () {
            $/ = \$length;
            local $/ = "\n";
            await XPerl::Task->delay(10);
        };
        my $ordinary_cleanup = async sub () {
            defer { ++$cleaned }
            await XPerl::Task->delay(10);
        };
        my $root = async sub () {
            my $a = $broken_cleanup->();
            my $b = $ordinary_cleanup->();
            await XPerl::Task->delay(0);
            $length = 0;
            die "root failure\n" if $fail_root;
            return 'root';
        };
        local $SIG{__WARN__} = sub { die "cleanup warning failure\n" };
        my $ok = eval { run($root->()); 1 };
        my $error = $@;
        ok(!$ok, 'cleanup warning failure reaches the driver caller');
        like($error, $fail_root ? qr/root failure/ : qr/cleanup warning failure/,
             'root failure takes precedence over cleanup failure');
        is($cleaned, 1, 'driver finishes other cleanup after a failure');
    }
}

async sub capture_task ($text) {
    $text =~ /(?<head>.)(.)?/p;
    my $before = [$1, $+, $^N, $+{head}, join(',', @-),
                  join(',', map { defined($_) ? $_ : 'undef' } @+), ${^MATCH}];
    my $inner;
    {
        "inner$text" =~ /(inner)(.*)/;
        await XPerl::Task->delay(0);
        $inner = [$1, $2];
    }
    return [$before, [$1, $+, $^N, $+{head}, join(',', @-),
                     join(',', map { defined($_) ? $_ : 'undef' } @+), ${^MATCH}], $inner];
}

async sub capture_pair () {
    my $a = capture_task("A");
    my $b = capture_task("\x{100}B");
    return [await $a, await $b];
}

{
    'caller' =~ /(.*)/;
    my $pair = run(capture_pair());
    is($1, 'caller', 'driving tasks preserves the caller capture');
    for my $index (0, 1) {
        my $text = $index ? "\x{100}B" : 'A';
        my ($before, $after, $inner) = @{$pair->[$index]};
        ok(eq_array($after, $before), 'outer match survives an interleaved inner scope');
        ok(eq_array($inner, ['inner', $text]), 'inner match belongs to its own task');
        is($after->[0], substr($text, 0, 1), 'numbered capture preserves its encoding');
        is($after->[6], $text, '/p match text survives suspension');
    }
}

async sub dynamic_capture ($text, $pattern) {
    $text =~ /$pattern/p;
    await XPerl::Task->delay(0);
    my $first = $1;
    $text =~ //;
    return [$first, $1];
}
async sub dynamic_pair () {
    my $a = dynamic_capture('a1', '(a)');
    my $b = dynamic_capture('b2', '(2)');
    return [await $a, await $b];
}
{
    my $pair = run(dynamic_pair());
    is(join(',', map { @$_ } @$pair), 'a,a,2,2',
       'dynamic regex bindings and empty patterns belong to the execution');
}

{
    my $factory = sub ($text) {
        return gen {
            $text =~ /(.)/;
            yield $1;
            yield $1;
            return $1;
        };
    };
    my ($a, $b) = ($factory->('A'), $factory->('B'));
    is(scalar $a->(), 'A', 'first generator captures its subject');
    is(scalar $b->(), 'B', 'second generator captures its subject');
    is(scalar $a->(), 'A', 'first generator retains its capture');
    undef $b;
    is(scalar $a->(), 'A', 'abandoning another generator preserves captures');

    'outside' =~ /(.*)/;
    my $fresh = gen { yield defined($1) ? $1 : 'no match' };
    is(scalar $fresh->(), 'no match', 'a fresh execution has no inherited match');
    is($1, 'outside', 'starting a fresh execution preserves the outside match');
}

for my $keyword (qw(async await)) {
    no strict 'refs';
    my $ok = eval { &{"CORE::$keyword"}(); 1 };
    ok(!$ok, "$keyword is parser syntax rather than a callable CORE sub");
    like($@, qr/Undefined subroutine|cannot be called directly/,
         "$keyword rejects an ampersand call without compiling a wrapper");
}

{
    my @destroyed;
    my $new_abandoned = sub {
        my $g = gen {
            my $guard = bless sub { push @destroyed, $1 }, 'AsyncCaptureGuard';
            'private' =~ /(.*)/;
            yield $1;
        };
        $g->();
        return $g;
    };
    no warnings qw(redefine once);
    local *AsyncCaptureGuard::DESTROY = sub { $_[0]->() };

    my $g = $new_abandoned->();
    my $text = 'outer';
    $text =~ s/(outer)/undef($g); $1/e;
    is($text, 'outer', 'abandonment in a replacement restores caller captures');
    is(join(',', @destroyed), 'private', 'replacement abandonment unwinds once with private captures');

    $g = $new_abandoned->();
    my $seen;
    $text =~ /(outer)(?{ undef $g; $seen = $1 })/;
    is($seen, 'outer', 'abandonment in regex code restores engine captures');
    is($1, 'outer', 'engine completes normally after abandonment');
    is(join(',', @destroyed), 'private,private', 'regex-code abandonment unwinds exactly once');
}

done_testing();
