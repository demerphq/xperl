#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use feature 'state';
use Config;
BEGIN {
    skip_all('requires interpreter threads') unless $Config{useithreads};
}
use threads;
use generator;
use builtin 'iter';
no warnings 'experimental::builtin';

sub is_deeply {
    my ($got, $expected, $name) = @_;
    ok(eq_array($got, $expected), $name);
}

my $n = 0;
my $plain = iter(sub { ++$n }, 4);
is($plain->(), 1, 'parent consumes first callable value');
is_deeply(threads->create(sub { [map { $_ } $plain] })->join, [2, 3],
          'child consumes its own copy of a callable adapter');
is_deeply([map { $_ } $plain], [2, 3], 'child does not change parent adapter state');

my $native = iter(gen { yield (10, 20); yield 30 });
is($native->(), 10, 'parent queues a native batch');
is_deeply(threads->create(sub { [map { $_ } $native] })->join, [20],
          'child receives queued values without resuming the parent continuation');
is_deeply([map { $_ } $native], [20, 30], 'parent continuation remains usable');

{
    use feature 'generator';
    my $bare = gen { yield 7 };
    ok(threads->create(sub { !defined iterator::state($bare) })->join,
       'generator continuation is skipped independently of adapter creation');
    is($bare->(), 7, 'parent generator remains usable after cloning');
}

my $loop_source = iter(sub { state $i = 0; ++$i }, 3);
for my $value ($loop_source) {
    is(threads->create(sub { $value })->join, $value,
       'cloning an active foreach keeps the current loop value');
}

sub thread_owner {
    gen {
        my ($park_first, $label) = @_;
        yield 'ready' if $park_first;
        my $joined = threads->create(sub { "child $_[0]" }, $label)->join;
        my $comparisons = 0;
        my @sorted = sort { ++$comparisons; $a cmp $b } qw(two one);
        yield [$joined, "@sorted", $comparisons > 0];
        return "done $label";
    };
}
for my $park_first (0, 1) {
    my $g = thread_owner();
    my $label = $park_first ? 'resumed call' : 'initial call';
    my $result = $g->($park_first, $label);
    if ($park_first) {
        is($result, 'ready', 'owner suspends before creating a thread');
        $result = $g->();
    }
    is_deeply($result, ["child $label", 'one two', 1],
              "thread creation and sort callbacks return to the generator on its $label");
    is($g->(), "done $label", "generator finishes after creating a thread on its $label");
}

done_testing;
