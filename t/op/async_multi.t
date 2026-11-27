#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use async;
use feature 'multisub';
no warnings qw(experimental::builtin experimental::multisub);

my @started;
async multi sub choose('double', $value) {
    push @started, $value;
    await XPerl::Task->delay(0);
    return $value * 2;
}
our $early;
BEGIN { $early = \&choose }
async multi sub choose() { return 42 }

is($early, \&choose, 'async group preserves early code references');
my $task = $early->('double', 21);
isa_ok($task, 'XPerl::Task');
is(scalar @started, 0, 'calling an async multi does not start dispatch');
is(run($task), 42, 'an early reference starts the completed async group');
is(run(choose()), 42, 'empty pattern clause returns a task too');

async sub together () {
    my $a = choose('double', 20);
    my $b = choose('double', 21);
    return [await $a, await $b];
}
ok(eq_array(run(together()), [40, 42]), 'interleaved clauses keep their own captures');

async sub positive ($value) { return $value > 0 }
async multi sub guarded($value if await positive($value)) { return $value }
async multi sub guarded($value) { return -$value }
is(run(guarded(7)), 7, 'a clause guard can await a dependency');
is(run(guarded(-7)), 7, 'a resumed false guard proceeds to the next clause');

async multi sub aliases($value) {
    await XPerl::Task->delay(0);
    $_[0] = 99;
    return $value;
}
my $argument = 42;
is(run(aliases($argument)), 42, 'pattern capture remains independent of the argument alias');
is($argument, 99, 'the async multi retains its original argument aliases');

async multi sub closure($value) {
    my $saved = $value;
    await XPerl::Task->delay(0);
    return sub { $saved };
}
async sub closures () {
    my $a = closure('A');
    my $b = closure('B');
    return [await $a, await $b];
}
my $closures = run(closures());
is($closures->[0]->(), 'A', 'first suspended clause retains its lexical storage');
is($closures->[1]->(), 'B', 'second suspended clause retains separate lexical storage');

async multi sub recurse(0) { return 0 }
async multi sub recurse($depth) { return $depth + await recurse($depth - 1) }
is(run(recurse(8)), 36, 'named recursion creates independent async multi tasks');

my $no_match_line = __LINE__ + 1;
$task = choose('missing');
is($task->state, 'pending', 'a nonmatching call still creates an unstarted task');
my $ok = eval { run($task); 1 };
my $no_match = ${^ERROR_OBJ}->contents->[0];
ok(!$ok, 'dispatch failure propagates when the task is driven');
ok($task->failed, 'dispatch failure leaves the task failed');
like($@, qr/No matching clause/, 'dispatch retains its no-match diagnostic');
is($no_match->location->{file}, __FILE__, 'deferred dispatch reports the async call file');
is($no_match->location->{line}, $no_match_line, 'deferred dispatch reports the async call line');

for my $declarations (
    'async multi sub mixed(1) { 1 } multi sub mixed(2) { 2 }',
    'multi sub mixed(1) { 1 } async multi sub mixed(2) { 2 }',
) {
    my $compiled = eval $declarations;
    like($@, qr/Cannot mix declaration kinds/, 'all clauses must agree on async');
}

require B;
my $factory = B::svref_2object(\&choose);
isa_ok($factory->ASYNC_BODY, 'B::CV');
isa_ok($factory->ASYNC_BODY->MULTISUB_SCOPES, 'B::AV');
isa_ok($factory->MULTISUB_SCOPES, 'B::SPECIAL');

my $program = <<'PERL';
use async;
use feature 'multisub';
no warnings qw(experimental::builtin experimental::multisub);
async multi sub calculate('plus', $value) {
    await XPerl::Task->delay(0);
    return $value + 1;
}
my $offset = 2;
async multi sub calculate('offset', $value) { return $value + $offset }
print run(calculate('plus', 41)), ',', run(calculate('offset', 40));
PERL
fresh_perl_is($program, '42,42', {}, 'async clauses preserve declaration-time lexical scopes');
my $sourcefile = tempfile();
open my $source, '>', $sourcefile or die "Cannot write $sourcefile: $!";
print {$source} $program;
close $source or die "Cannot close $sourcefile: $!";
my $deparsed = runperl(switches => ['-MO=Deparse'], progfile => $sourcefile, stderr => 1);
$deparsed =~ s/^\Q$sourcefile\E syntax OK\n//m;
like($deparsed, qr/async multi sub calculate/, 'deparser preserves async multi declarations');
fresh_perl_is($deparsed, '42,42', {}, 'deparsed async clauses compile and run');

fresh_perl_is(<<'PERL', 'Other::named', {}, 'async multi body retains its qualified caller name');
use xperl;
package Other;
async multi sub named(1) { return (caller(0))[3] }
print run(named(1));
PERL

fresh_perl_is(<<'PERL', 'created-task.pl:412', {}, 'call location outlives a string eval and retains conditional lines');
use xperl;
my $task = eval q{
    async multi sub only(1) { return 42 }
#line 301 "created-task.pl"
    if (1) {
#line 412 "created-task.pl"
        only(2);
    }
};
eval { run($task) };
my $where = ${^ERROR_OBJ}->contents->[0]->location;
print "$where->{file}:$where->{line}";
PERL

fresh_perl_is(<<'PERL', 'released', {}, 'async multi has no factory cycle after introspection and stash deletion');
use xperl;
require B;
my $code = eval q{package AsyncMultiWeak; async multi sub alive(1) { 42 } \&alive};
B::svref_2object($code)->ASYNC_BODY->GV;
weaken($code);
delete $AsyncMultiWeak::{alive};
print defined($code) ? 'retained' : 'released';
PERL

fresh_perl_is(<<'PERL', 'released', {}, 'pending task does not retain its creator package');
use xperl;
async multi sub target(1) { 42 }
my $task = eval q{package AsyncCreator; our $pending = main::target(2); $pending};
weaken($task);
delete $main::{'AsyncCreator::'};
print defined($task) ? 'retained' : 'released';
PERL

fresh_perl_is(<<'PERL', 'nested-call.pl:87', {}, 'synchronous no-match in a selected clause retains its own call location');
use xperl;
multi sub sync_only(1) { 42 }
async multi sub selected(1) {
#line 87 "nested-call.pl"
    sync_only(2);
}
eval { run(selected(1)) };
my $where = ${^ERROR_OBJ}->contents->[0]->location;
print "$where->{file}:$where->{line}";
PERL

SKIP: {
    skip('German diagnostics extension is unavailable', 1)
        unless _have_dynamic_extension('XPerl::DiagPack::DE');
    fresh_perl_is(<<'PERL', 'creation.de:33,German', {}, 'deferred dispatch retains the lexical language of its call');
use xperl;
async multi sub localized(1) { 42 }
my $task;
{
    use diagpack 'de';
#line 33 "creation.de"
    $task = localized(2);
}
eval { run($task) };
my $exception = ${^ERROR_OBJ};
my $where = $exception->contents->[0]->location;
print "$where->{file}:$where->{line},";
print $exception->render eq $exception->render_as_legacy('de') ? 'German' : 'wrong';
PERL
}

async multi sub explode($value) {
    await XPerl::Task->delay(0);
    die "clause failure $value\n";
}
eval { run(explode(42)) };
like($@, qr/clause failure 42/, 'an exception after awaiting escapes the selected clause');

{
    use feature 'defer';
    no warnings 'experimental::defer';
    my $cleaned = 0;
    async multi sub abandoned('wait') {
        defer { ++$cleaned }
        await XPerl::Task->delay(10);
    }
    async sub finish_first () {
        my $pending = abandoned('wait');
        await XPerl::Task->delay(0);
        return 42;
    }
    is(run(finish_first()), 42, 'root can finish with a suspended async clause');
    is($cleaned, 1, 'driver cancellation unwinds the suspended clause');
}

fresh_perl_is(<<'PERL', 'incomplete,42', {}, 'early calls diagnose an unfinished group without breaking it');
use xperl;
async multi sub pending('a') { return 41 }
BEGIN {
    my $ok = eval { pending('b'); 1 };
    print $ok ? 'unexpected,' : 'incomplete,';
}
async multi sub pending('b') { return 42 }
print run(pending('b'));
PERL

done_testing();
