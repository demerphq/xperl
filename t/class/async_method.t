#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
    skip_all_without_dynamic_extension('B');
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use feature qw(class multisub state);
use async;
no warnings qw(experimental::class experimental::multisub experimental::builtin);

class AsyncCounter {
    field $value :param;
    async method add($amount = 1) {
        await XPerl::Task->delay(0);
        return $value += $amount;
    }
    async method current { return $value }
    async method alias { $_[0] = 99; return $value }
    async method recurse($depth) {
        return $depth ? await $self->recurse($depth - 1) : $value;
    }
    my async method hidden($amount) {
        await XPerl::Task->delay(0);
        return $value + $amount;
    }
    async method private_call($amount) { return await $self->&hidden($amount) }
    state async method next_count {
        state $calls = 0;
        await XPerl::Task->delay(0);
        return [$value, ++$calls];
    }
    async method private_state { return await $self->&next_count }
    method callback {
        return async method($amount) {
            await XPerl::Task->delay(0);
            return $value + $amount;
        };
    }
    async multi method act('add', $amount) {
        await XPerl::Task->delay(0);
        return $value += $amount;
    }
    async multi method act('get') { return $value }
}

my $object = AsyncCounter->new(value => 10);
my $task = $object->add(2);
isa_ok($task, 'XPerl::Task');
is(run($object->current), 10, 'calling an async method does not start its body');
is(run($task), 12, 'method fields and parameters survive an await');
is(run($object->add), 13, 'method signature defaults work');
is(run($object->recurse(4)), 13, 'named method recursion creates tasks');
is(run($object->private_call(2)), 15, 'private lexical async methods can await');
my $callback = $object->callback;
is(run($object->$callback(7)), 20, 'anonymous async methods can await');
ok(!$object->can('hidden'), 'private method has no public method entry');
is(run($object->act('add', 3)), 16, 'async multi method dispatch skips the receiver');
is(run($object->act('get')), 16, 'async multi clauses share the object fields');
my $argument = 0;
run($object->alias($argument));
is($argument, 99, 'ordinary method arguments retain async alias semantics');
ok(eq_array(run($object->private_state), [16, 1]),
   'state lexical async methods can await with object fields');
my $no_match = $object->act('unknown');
eval { run($no_match) };
like($@, qr/No matching clause for multi method/, 'multi method failure is delivered by the task');

my $original = AsyncCounter->new(value => 41);
ok(eq_array(run($original->private_state), [41, 2]),
   'state persists while each invocation binds its own object');
my $selected = $original->current;
$original = AsyncCounter->new(value => 99);
is(run($selected), 41, 'pending method retains the receiver selected at the call');
$selected = $original->current;
undef $original;
is(run($selected), 99, 'pending method keeps its receiver alive');

class AsyncBase {
    field $base = 10;
    async method total($extra) {
        await XPerl::Task->delay(0);
        return $base + $extra;
    }
}
class AsyncDerived :isa(AsyncBase) {
    field $derived = 20;
    async method total($extra) {
        return $derived + await $self->SUPER::total($extra);
    }
}
is(run(AsyncDerived->new->total(12)), 42, 'SUPER keeps the declaring method context');

role AsyncRole {
    field $count :param;
    my async method private_count {
        await XPerl::Task->delay(0);
        return $count;
    }
    async method count { return await $self->&private_count }
    method callback {
        return async method {
            await XPerl::Task->delay(0);
            return $count;
        };
    }
    async multi method choose('count') {
        await XPerl::Task->delay(0);
        return $count;
    }
}
role AsyncMiddle :implements(AsyncRole) {}
class AsyncRoleLeft :implements(AsyncMiddle) {}
class AsyncRoleRight :isa(AsyncBase) :implements(AsyncMiddle) {}
async sub role_pair() {
    my $left = AsyncRoleLeft->new(count => 11)->count;
    my $right = AsyncRoleRight->new(count => 22)->count;
    return [await $right, await $left];
}
ok(eq_array(run(role_pair()), [22, 11]),
   'transitive role methods retain separate consumer offsets while suspended');
my $right = AsyncRoleRight->new(count => 42);
is(run($right->choose('count')), 42, 'composed async multi method retains its role field mapping');
$callback = $right->callback;
is(run($right->$callback), 42, 'an escaped anonymous async method retains its role consumer');

SKIP: {
    skip 'requires ithreads', 2 unless $Config::Config{useithreads};
    skip 'requires threads extension', 2 unless eval { require threads; 1 };
    my $thread = threads->create(sub {
        my $object = AsyncRoleRight->new(count => 42);
        return [run($object->count), run($object->choose('count'))];
    });
    ok(eq_array($thread->join, [42, 42]), 'child interpreter clones role method factories');
    is(run($right->count), 42, 'parent method remains usable after interpreter cloning');
}

fresh_perl_is(<<'PERL', '1', {}, 'creator magic cannot replace the selected receiver');
use xperl;
class MagicCounter { field $value :param; async method value { $value } }
our $first = MagicCounter->new(value => 1);
our $second = MagicCounter->new(value => 2);
package ReassignReceiver {
    sub TIESCALAR { bless {}, shift }
    sub FETCH { $main::first = $main::second; 'topic' }
}
my $task;
{ local $_; tie $_, 'ReassignReceiver'; $task = $first->value }
print run($task);
PERL

fresh_perl_is(<<'PERL', '2:2,1:1,2:2', {}, 'tied receivers provide one object for self and fields');
use xperl;
class TiedCounter {
    field $value :param;
    method plain() { $value }
    async method value { "$value:" . $self->plain }
}
our @objects = (TiedCounter->new(value => 1), TiedCounter->new(value => 2));
package AlternatingReceiver {
    sub TIESCALAR { bless {next => 0}, shift }
    sub FETCH { $main::objects[$_[0]{next}++ % 2] }
}
tie my $named, 'AlternatingReceiver';
my $code = TiedCounter->can('value');
tie my $direct, 'AlternatingReceiver';
tie my $primed, 'AlternatingReceiver';
my $ignore = $primed;
print join ',', run($named->value), run($code->($direct)), run($primed->$code);
PERL

fresh_perl_is(<<'PERL', 'released', {}, 'an unstarted cancelled method releases its receiver');
use xperl;
class KeptReceiver {
    async method wait { await XPerl::Task->delay(60) }
}
my $object = KeptReceiver->new;
my $weak = $object;
weaken($weak);
my $task = $object->wait;
undef $object;
die 'receiver lost too soon' unless defined $weak;
$task->cancel;
undef $task;
print defined $weak ? 'retained' : 'released';
PERL

fresh_perl_is(<<'PERL', '42', {}, 'cancelling a suspended method restores its fields for cleanup');
use xperl;
our @cleaned;
class StoppedReceiver {
    field $value :param;
    async method wait {
        defer { push @cleaned, $value }
        await XPerl::Task->delay(60);
    }
}
async sub stop_method() {
    my $task = StoppedReceiver->new(value => 42)->wait;
    await XPerl::Task->delay(0);
    die 'method did not suspend' unless $task->state eq 'waiting';
    $task->cancel;
}
run(stop_method());
print join ',', @cleaned;
PERL

fresh_perl_is(<<'PERL', '42', {}, 'a private async helper named DESTROY is not a lifecycle hook');
use xperl;
class PrivateHookName {
    my async method DESTROY() { 42 }
    async method answer() { await $self->&DESTROY }
}
print run(PrivateHookName->new->answer);
PERL

my $program = <<'PERL';
use feature qw(class async signatures);
no warnings 'experimental::class';
class DeparsedAsync {
    field $value;
    async method add($amount) { return await XPerl::Task->resolved($value + $amount) }
}
PERL
fresh_perl_like($program, qr/async method add \(\$amount\).*await/s,
                {switches => ['-MO=Deparse']}, 'deparser retains the async method declaration');

my $invalid_class = 0;
for my $kind ('async sub', 'async method') {
    my $class = 'InvalidLvalue' . ++$invalid_class;
    eval "use xperl; class $class { method make() { return $kind :lvalue () { our \$v; \$v } } }";
    ok($@, "anonymous $kind rejects an lvalue result");
    is(${^ERROR_OBJ}->diagnostics->[0]->code, 'ERROR_ASYNC_DECLARATION_UNSUPPORTED',
       'anonymous lvalue rejection uses the async declaration diagnostic');
}

for my $kind ('async method', 'async multi method', 'async sub') {
    for my $name (qw(DESTROY TEARDOWN)) {
        my $class = 'InvalidHook' . ++$invalid_class;
        my $program = "use xperl; class $class { $kind $name () {} }";
        eval $program;
        ok($@, "$kind $name is rejected because automatic cleanup is synchronous");
        is(${^ERROR_OBJ}->diagnostics->[0]->code, 'ERROR_ASYNC_DECLARATION_UNSUPPORTED',
           'cleanup hook rejection uses the async declaration diagnostic');
    }
}

done_testing();
