#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;
use feature qw(defer try);
no warnings qw(experimental::defer experimental::try);

our (@array, %hash, $scalar, $other);
@array = ('outside');
%hash = (present => 'outside');
$scalar = 'outside';
$other = 'other';

# These scopes cannot be parked. A failed yield must leave their bindings
# installed so normal exception handling can unwind them.
my @cases = (
    ['existing array element', q{local $array[0] = 'inside'}, q{$array[0]}],
    ['missing array element', q{local $array[5] = 'inside'}, q{$array[5]}],
    ['existing hash element', q{local $hash{present} = 'inside'}, q{$hash{present}}],
    ['missing hash element', q{local $hash{missing} = 'inside'}, q{$hash{missing}}],
    ['array slice', q{local @array[0, 5] = ('inside', 'inside')}, q{$array[0]}],
    ['hash slice', q{local @hash{'present', 'missing'} = ('inside', 'inside')}, q{$hash{present}}],
    ['delete local hash element', q{delete local $hash{present}}, q{exists $hash{present} ? 'wrong' : 'inside'}],
    ['delete local missing hash element', q{delete local $hash{missing}}, q{exists $hash{missing} ? 'wrong' : 'inside'}],
    ['glob', q{local *scalar = *other}, q{$scalar eq 'other' ? 'inside' : 'wrong'}],
    ['error number', q{local $! = 2}, q{0 + $! == 2 ? 'inside' : 'wrong'}],
);

for my $case (@cases) {
    my ($name, $setup, $observe) = @$case;
    my ($error, $still_inside);
    my $g = eval "gen {
        {
            $setup;
            eval { yield 'must not escape' };
            \$error = \$\@;
            \$still_inside = $observe;
        }
        yield 'scope ended';
        return 'finished';
    }";
    die $@ unless $g;
    is(scalar $g->(), 'scope ended', "$name rejects yield until scope ends");
    like($error, qr/Cannot yield with an unsupported localization still in scope/,
         "$name reports unsupported localization");
    is($still_inside, 'inside', "$name stays installed after the caught error");
    is($array[0], 'outside', "$name leaves outside array intact");
    is($hash{present}, 'outside', "$name leaves outside hash intact");
    ok(!exists $hash{missing} && !exists $array[5], "$name restores absent elements");
    is($scalar, 'outside', "$name leaves outside scalar intact");
    is(scalar $g->(), 'finished', "$name permits resumption after scope exit");
}

{
    my $g = gen { local $hash{present} = 'inside'; yield 'blocked' };
    my $ok = eval { scalar $g->(); 1 };
    ok(!$ok, 'uncaught rejection propagates to the caller');
    like($@, qr/unsupported localization/, 'caller receives the yield diagnostic');
    is($hash{present}, 'outside', 'uncaught rejection unwinds the local');
}

{
    my ($owned, $during, $error);
    my $outside = \$scalar;
    my $g = gen {
        local $scalar = 'supported';
        $owned = \$scalar;
        {
            local $hash{present} = 'unsupported';
            eval { yield 'blocked' };
            $error = $@;
            $during = \$scalar;
            is($scalar, 'supported', 'failed preflight keeps supported locals installed');
        }
        yield \$scalar;
        return \$scalar;
    };
    ok(scalar($g->()) == $owned, 'valid retry parks the original localized scalar');
    ok($during == $owned, 'failed preflight does not replace lexical storage');
    like($error, qr/unsupported localization/, 'mixed binding plan rejects its unsupported local');
    ok(\$scalar == $outside, 'successful suspension restores the outside scalar');
    ok(scalar($g->()) == $owned, 'resumption retains the supported scalar identity');
}

sub temporary_local {
    local $hash{present} = 'helper';
    return $hash{present};
}
{
    my $g = gen {
        my $answer = temporary_local();
        yield $answer;
        { local $hash{present} = 'return'; return $hash{present} }
    };
    is(scalar $g->(), 'helper', 'completed helper locals do not prevent yielding');
    is(scalar $g->(), 'return', 'unsupported local may remain active on normal return');
    is($hash{present}, 'outside', 'normal return restores its local');
}

{
    local $hash{present} = 'caller';
    my $g = gen { yield 'owner'; return 'done' };
    is(scalar $g->(), 'owner', 'caller save entries are outside the checked stack');
    is($hash{present}, 'caller', 'caller element local stays installed');
    is(scalar $g->(), 'done', 'caller local does not prevent completion');
}

for my $end (qw(return abandon)) {
    my @events;
    my $g = gen {
        defer { push @events, 'defer' }
        try { yield 'pending' }
        catch ($error) { die $error }
        finally { push @events, 'finally' }
        return 'done';
    };
    is(scalar $g->(), 'pending', "$end permits pending defer and finally");
    is(scalar @events, 0, "$end does not run cleanup at yield");
    if ($end eq 'return') {
        is(scalar $g->(), 'done', 'normal completion leaves the protected scope');
    }
    else {
        undef $g;
    }
    is(join(',', @events), 'finally,defer', "$end runs pending cleanup at scope exit");
}

{
    use feature qw(refaliasing declared_refs);
    no warnings qw(experimental::refaliasing experimental::declared_refs);
    my $referent = 'outside';
    my $g = gen {
        for \our $reference_alias (\$referent) {
            yield 'blocked';
        }
    };
    my $ok = eval { scalar $g->(); 1 };
    ok(!$ok, 'package reference iterator rejects suspension without other locals');
    like($@, qr/unsupported localization/, 'reference iterator reports its unsupported binding');
    is($referent, 'outside', 'rejection preserves the aliased value');
}

done_testing;
