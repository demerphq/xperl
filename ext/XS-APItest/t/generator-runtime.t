#!perl

BEGIN {
    chdir 't' if -d 't';
    require '../../../t/test.pl';
    set_up_inc('../../../lib');
}

use strict;
use warnings;
use feature 'lexical_subs';
use XS::APItest;
use generator;
use builtin 'iter';
no warnings 'experimental::builtin';

plan(tests => 14);

SKIP: {
    my $caller_names = scope_name_stack_address();
    skip 'requires debugging scope names', 3 unless $caller_names;
    my $owner = gen { yield scope_name_stack_address() };
    isnt($owner->(), $caller_names, 'a suspended context owns its scope names');
    is(scope_name_stack_address(), $caller_names, 'yield restores caller scope names');
    undef $owner;
    is(scope_name_stack_address(), $caller_names, 'cleanup restores caller scope names');
}

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
    my $count = grep { 0 } iter($it);
}), 0, 'native lazy consumption releases yielded values');

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

sub escaping_subs {
    gen {
        my $x = $_[0];
        my sub reader { $x }
        my $fail = yield [\&reader, sub { $x }];
        die "generator failed\n" if $fail;
        return $x;
    };
}
for my $exit (qw(return fail drop)) {
    is(growth(sub {
        for (1 .. 25) {
            my $owner = escaping_subs();
            my $readers = $owner->('value');
            if ($exit eq 'return') {
                $owner->();
            }
            elsif ($exit eq 'fail') {
                eval { $owner->(1) };
            }
            undef $owner;
            $_->() for @$readers;
        }
    }), 0, "escaped lexical and anonymous subs release their pads after $exit");
}
