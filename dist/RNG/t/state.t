use strict;
use warnings;
use Test::More;
use RNG ();
use RNG::Seed ();
use Config;

my @classes = qw(
    RNG::Drand48 RNG::PCG RNG::PCG::RXS_M_XS_64_64
    RNG::PCG::XSL_RR_128_64_MCG RNG::PCG::XSL_RR_128_64_LCG
    RNG::Wyrand RNG::Xoshiro RNG::HMAC_DRBG
);

{
    package RNG::StateTest::Overload;
    use overload '""' => sub { $_[0]{callback}->(); $_[0]{value} },
                 bool => sub { 1 },
                 fallback => 1;
}

{
    package RNG::StateTest::Seed;
    our @ISA = 'RNG::SeedBase';
    sub is_redacted { $_[0]{callback}->(); 0 }
    sub bytes { $_[0]{bytes} }
}

for my $class (@classes) {
    (my $file = "$class.pm") =~ s!::!/!g;
    require $file;

    my $rng = $class->new(42);
    my $saved = $rng->state;
    my $copy = $saved;
    my $expected = $rng->rand_bytes(64);
    is($saved, $copy, "$class draws leave snapshots unchanged");
    $rng->set_state($saved);
    is($rng->rand_bytes(64), $expected, "$class restores its stream");
    is($saved, $copy, "$class restore leaves its argument unchanged");

    my $before = $rng->state;
    eval { $rng->set_state('x') };
    like($@, qr/state has the wrong length/, "$class rejects a wrong-sized state");
    is($rng->state, $before, "$class failed restore preserves state");
    eval { $rng->set_state("\x{100}") };
    like($@, qr/Wide character/, "$class rejects wide state characters");

    eval { $$rng = 'x' };
    like($@, qr/read-only/, "$class referent is read-only");

    Internals::SvREADONLY($$rng, 0);
    $$rng = 'replacement scalar contents';
    $rng->set_state($saved);
    is($rng->rand_bytes(64), $expected,
       "$class scalar replacement cannot change native state");

    my $argument = bless {
        callback => sub { $rng->set_state($saved) }, value => 'replacement seed',
    }, 'RNG::StateTest::Overload';
    $rng->srand($argument);
    is($rng->rand_bytes(32), $class->new('replacement seed')->rand_bytes(32),
       "$class seed conversion completes before updating native state");

    my $constructor_class = $class;
    my $constructor_seed = bless {
        callback => sub { $constructor_class = 'x' x 10000 },
        value => 'constructor seed',
    }, 'RNG::StateTest::Overload';
    my $constructed = $constructor_class->new($constructor_seed);
    is(ref($constructed), $class, "$class retains its class across seed callbacks");
    is($constructed->rand_bytes(32), $class->new('constructor seed')->rand_bytes(32),
       "$class constructor finishes converting seed material safely");

    my $seed_width = $class eq 'RNG::Drand48' ? 6
                   : $class eq 'RNG::HMAC_DRBG' ? 64
                   : $class eq 'RNG::Xoshiro' || $class =~ /_LCG$/ ? 32
                   : $class eq 'RNG::PCG' || $class =~ /_MCG$/ ? 16 : 8;
    my $raw_seed = RNG::Seed->from_bytes("\0" x $seed_width);
    my $raw = bless {
        bytes => $raw_seed->bytes, callback => sub { $rng->set_state($saved) },
    }, 'RNG::StateTest::Seed';
    $rng->srand($raw);
    is($rng->rand_bytes(32), $class->new($raw_seed)->rand_bytes(32),
       "$class raw seed callbacks complete before updating native state");

    my $snapshot_arg = bless {
        callback => sub { $rng->srand('intervening seed') }, value => $saved,
    }, 'RNG::StateTest::Overload';
    $rng->set_state($snapshot_arg);
    is($rng->rand_bytes(64), $expected,
       "$class restore converts its argument before accessing state");

    SKIP: {
        skip 'native RNG required', 2 unless $RNG::HAS_NATIVE_RNG;
        local ${^RNG} = $rng;
        $rng->set_state($saved);
        my $draw = rand();
        $rng->set_state($saved);
        is(rand(), $draw, "$class core draws use the restored state");
        is($saved, $copy, "$class core draws leave snapshots unchanged");
    }

    SKIP: {
        skip 'Perl was not built with threads', 3 unless $Config{useithreads};
        require threads;
        $rng->set_state($saved);
        local ${^RNG} = $rng;
        my $thread = threads->create(sub {
            my $snapshot = ${^RNG}->state;
            my $draw = rand();
            ${^RNG}->srand('child seed');
            return [$snapshot, $draw];
        });
        my $child = $thread->join;
        is($child->[0], $saved, "$class thread inherits the state bytes");
        is($rng->state, $saved, "$class child updates leave parent state unchanged");
        is(rand(), $child->[1], "$class parent and child start with the same stream");
    }
}

{
    my $rng = RNG::HMAC_DRBG->new(42);
    my $saved = $rng->state;
    for my $byte (2, 255) {
        eval { $rng->set_state(chr($byte) x length($saved)) };
        like($@, qr/state contains invalid flags/, 'HMAC_DRBG rejects malformed flags');
        is($rng->state, $saved, 'a rejected flag representation preserves live state');
        is($rng->is_secure, 0, 'a rejected snapshot preserves deterministic mode');
    }

    SKIP: {
        my $secure = eval { RNG::HMAC_DRBG->new_secure };
        skip 'operating-system entropy unavailable', 4 unless $secure;
        my $disabled = $secure->state;
        $secure->prediction_resistance(1);
        my $enabled = $secure->state;
        my ($flag_offset) = grep {
            substr($disabled, $_, 1) ne substr($enabled, $_, 1)
        } 0 .. length($disabled) - 1;
        ok(defined($flag_offset), 'snapshots record prediction resistance');
        if (defined $flag_offset) {
            my $bad = $enabled;
            substr($bad, $flag_offset, 1) = "\xff";
            eval { $secure->set_state($bad) };
            like($@, qr/state contains invalid flags/,
                 'HMAC_DRBG rejects malformed prediction resistance');
            is($secure->state, $enabled, 'a rejected prediction flag preserves live state');
        }
        $secure->set_state($disabled);
        ok(!$secure->prediction_resistance, 'a valid snapshot restores prediction resistance');
    }
}

done_testing;
