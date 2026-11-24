#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;

{
    local $_ = 'caller';
    my $caller = \$_;
    my $g = gen {
        my $argument = \$_[0];
        $_ = 'outer owner';
        my $outer = \$_;
        {
            local $_ = 'inner owner';
            my $inner = \$_;
            yield [$argument, $outer, $inner];
            $_ .= '+';
        }
        yield $outer;
        return $_;
    };
    my $saved = $g->($_);
    is($saved->[0], $caller, 'initial topic argument aliases the caller scalar');
    is(${$saved->[0]}, 'caller', 'initial argument keeps the caller value');
    is(\$_, $caller, 'suspension preserves the caller topic identity');
    isnt($saved->[1], $caller, 'owner has an independent topic scalar');
    isnt($saved->[2], $saved->[1], 'local topic has its own scalar');
    is(${$saved->[1]}, 'outer owner', 'escaped outer topic retains its value');
    is(${$saved->[2]}, 'inner owner', 'escaped local topic retains its value');
    {
        local $_ = 'new resumer';
        my $resumer = \$_;
        is($g->(), $saved->[1], 'resumption restores the outer topic by identity');
        is(\$_, $resumer, 'resumption preserves a different caller topic identity');
        is($_, 'new resumer', 'resumption preserves the current caller topic value');
    }
    is(${$saved->[2]}, 'inner owner+', 'local topic can change before its scope ends');
    is($g->(), 'outer owner', 'completion sees the outer topic');
    is(\$_, $caller, 'completion restores the original caller scalar');
    is($_, 'caller', 'completion preserves its value');
}

{
    local $_ = 'outside';
    my $outside = \$_;
    my @values = ('first', 'second');
    my $g = gen {
        for (@values) {
            yield \$_;
            $_ .= '+';
        }
        return 'end';
    };
    my $first = $g->();
    is($first, \$values[0], 'foreach topic aliases the first array element');
    is(\$_, $outside, 'foreach suspension restores the outside scalar');
    $$first = 'edited';
    my $second = $g->();
    is($second, \$values[1], 'foreach topic advances to the next array element');
    is($values[0], 'edited+', 'resumption updates the original first element');
    is($g->(), 'end', 'foreach generator completes');
    is($values[1], 'second+', 'completion updates the original second element');
    is(\$_, $outside, 'foreach completion restores the caller scalar');
}

{
    package GeneratorBindingTie;
    sub TIESCALAR { bless [$_[1], $_[2]], shift }
    sub FETCH { push @{$_[0][1]}, 'fetch'; $_[0][0] }
    sub STORE { push @{$_[0][1]}, 'store'; $_[0][0] = $_[1] }
}
{
    local $_ = 'outside';
    my $g = gen {
        local $_;
        my @calls;
        tie $_, 'GeneratorBindingTie', 'tied owner', \@calls;
        yield [\$_, \@calls];
        $_ = 'edited';
        return $_;
    };
    my @caller_calls;
    tie $_, 'GeneratorBindingTie', 'tied caller', \@caller_calls;
    my $caller = \$_;
    my $result = $g->();
    is(scalar @caller_calls, 0, 'switching does not fetch or store the tied caller topic');
    is(\$_, $caller, 'tied caller retains its scalar');
    ok(tied(${$result->[0]}), 'parked local retains its tie');
    is(${$result->[0]}, 'tied owner', 'parked local retains its value');
    is($g->(), 'edited', 'resumed local retains its backing object');
    is(scalar @caller_calls, 0, 'resumption does not invoke caller topic magic');
    is($_, 'tied caller', 'caller tie retains its backing object');
}

done_testing;
