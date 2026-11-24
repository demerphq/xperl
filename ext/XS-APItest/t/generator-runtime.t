#!perl

BEGIN {
    chdir 't' if -d 't';
    require '../../../t/test.pl';
    set_up_inc('../../../lib');
}

use strict;
use warnings;
use XS::APItest;
use generator;

plan(tests => 8);

ok(process_state_roundtrip(), 'process state saves and restores');
is(process_scheduler_reject(), -1, 'scheduler rejects an incomplete setup');
ok(process_scheduler_switch(), 'scheduler alternates independent process states');

# Warm the same code before measuring, so cached pads and other first-use
# allocations do not look like values retained by an iterator invocation.
sub growth {
    my ($work) = @_;
    $work->();
    my $before = sv_count();
    $work->();
    return sv_count() - $before;
}

is(growth(sub {
    my $it = iterator->new(sub {});
    iterator::state($it) for 1 .. 100;
}), 0, 'state lookups release their returned values');

is(growth(sub {
    my $it = gen { yield $_ for 1 .. 100 };
    while (!$it->exhausted) { my @values = $it->() }
}), 0, 'native generator calls release yielded values');

is(growth(sub {
    my $it = gen { return };
    $it->() for 1 .. 100;
}), 0, 'completed calls release their argument arrays');

is(growth(sub {
    my $it = gen { my $value = yield() for 1 .. 100 };
    $it->();
    $it->(23, 24) for 1 .. 100;
}), 0, 'scalar yield expressions release resumed values');

is(growth(sub {
    my $it = gen { my @values = yield() for 1 .. 100 };
    $it->();
    $it->(23, 24) for 1 .. 100;
}), 0, 'list yield expressions release resumed values');
