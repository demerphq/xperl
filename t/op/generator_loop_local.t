#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;

our $item = 'host';
my $root = \$item;
sub owner {
    my ($values) = @_;
    gen {
        for $item (@$values) {
            yield [$item, \$item];
        }
        return 'done';
    };
}

{
    my @left = ('A1', 'A2');
    my @right = ('B1', 'B2');
    my ($a, $b) = (owner(\@left), owner(\@right));
    my $first = $a->();
    is($first->[0], 'A1', 'first owner enters its package loop');
    ok($first->[1] == \$left[0], 'loop retains its array-element alias');
    ok(\$item == $root && $item eq 'host', 'yield restores caller scalar identity');
    is($b->()->[0], 'B1', 'second owner enters the same package loop');
    ${$first->[1]} = 'edited A1';
    {
        local $item = 'another caller';
        my $host = \$item;
        is($a->()->[0], 'A2', 'first owner advances independently');
        ok(\$item == $host && $item eq 'another caller', 'loop yields into the current caller binding');
        is($a->(), 'done', 'older owner finishes first');
        ok(\$item == $host && $item eq 'another caller', 'loop completion restores the current caller');
    }
    is($b->()->[0], 'B2', 'younger owner remains valid after older completion');
    is($b->(), 'done', 'younger owner finishes');
    is($left[0], 'edited A1', 'held reference keeps the original aliased element');
    ok(\$item == $root && $item eq 'host', 'both completions restore root identity');
}

{
    my $make = sub {
        my ($name) = @_;
        my @outer = ("$name outer");
        my @inner = ("$name inner");
        gen {
            local $item = "$name local";
            for $item (@outer) {
                yield $item;
                for $item (@inner) {
                    yield $item;
                    {
                        local $item = "$name nested local";
                        yield $item;
                    }
                    yield $item;
                }
                yield $item;
            }
            return $item;
        };
    };
    my ($a, $b) = ($make->('A'), $make->('B'));
    for my $suffix ('outer', 'inner', 'nested local', 'inner', 'outer', 'local') {
        is($b->(), "B $suffix", 'younger owner follows mixed binding order');
        is($a->(), "A $suffix", 'older owner follows mixed binding order');
        is($item, 'host', 'mixed bindings expose caller between activations');
    }
}

{
    package LoopLocalGuard;
    sub DESTROY { $_[0][0]->() }
}
for my $end ('return', 'die', 'abandon') {
    my @seen;
    my @values = ("$end value");
    my $g = gen {
        for $item (@values) {
            my $guard = bless [sub { push @seen, $item }], 'LoopLocalGuard';
            yield $item;
            die "owner failure\n" if $end eq 'die';
            return $item;
        }
    };
    is($g->(), "$end value", "$end owner suspends in package loop");
    $item = 'caller edit';
    if ($end eq 'abandon') {
        undef $g;
    }
    else {
        my $value = eval { scalar $g->() };
        if ($end eq 'die') {
            like($@, qr/owner failure/, 'loop failure propagates');
        }
        else {
            is($value, 'return value', 'return sees its loop alias');
        }
    }
    is(join(',', @seen), "$end value", "$end cleanup sees owner alias");
    ok(\$item == $root && $item eq 'caller edit', "$end preserves caller edits and identity");
    $item = 'host';
}

{
    my @owners;
    my @steps;
    my @values;
    for my $i (0 .. 15) {
        $values[$i] = [map { "$i:$_" } 0 .. 3];
        $owners[$i] = owner($values[$i]);
        $steps[$i] = 0;
    }
    my $state = 1729;
    my @live = 0 .. $#owners;
    while (@live) {
        $state = (25173 * $state + 13849) % 65536;
        my $selected = $state % @live;
        my $i = $live[$selected];
        if ($steps[$i] == 4) {
            is($owners[$i]->(), 'done', 'randomly selected owner completes');
            undef $owners[$i];
            splice @live, $selected, 1;
        }
        else {
            my $value = $owners[$i]->();
            is($value->[0], "$i:$steps[$i]", 'random interleaving retains loop value');
            ok($value->[1] == \$values[$i][$steps[$i]], 'random interleaving retains element alias');
            ++$steps[$i];
        }
        ok(\$item == $root && $item eq 'host', 'random interleaving restores caller');
    }
}

{
    our ($special_alias, $untouched);
    no strict 'refs';
    local *special_alias = *{'main::@'};
    local $untouched = 'caller';
    my $outside = \$untouched;
    my $g = gen {
        for $special_alias ('owner') {
            yield 'park';
        }
    };
    eval { $g->() };
    like($@, qr/generator continuation is not available|unsupported localization/,
         'unsupported special loop alias rejects suspension');
    *special_alias = *untouched;
    undef $g;
    is($untouched, 'caller', 'retargeted rejected loop leaves caller value alone');
    ok(\$untouched == $outside, 'retargeted rejected loop leaves caller binding alone');
}

done_testing;
