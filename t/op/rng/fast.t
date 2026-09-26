#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}

use strict;
use warnings;
use XS::APItest ();
use RNG::Provider ();
use RNG::PCG ();
use RNG::Drand48 ();
use RNG::Seed ();
use builtin ();
no warnings 'experimental::builtin';

{
    package RNG::FastTest;
    our @ISA = 'RNG::Provider';
    sub new { bless \(my $value = 1), shift }
    sub rand_bytes { "\0" x $_[1] }
    sub srand { $_[1] }
}

{
    package RNG::FastTest::Aliasing;
    our @ISA = 'RNG::FastTest';
    our $replacement;
    sub rand_bytes {
        $_[0] = $replacement;
        return "\0" x $_[1];
    }
}

{
    package RNG::FastTest::SeedCallback;
    our @ISA = 'RNG::FastTest';
    our $callback;
    sub srand { $callback->(@_) }
}

my $provider = RNG::FastTest->new;
ok(!XS::APItest::rng_fast_find($provider), 'no registration on a new object');
XS::APItest::rng_fast_register($provider);
ok(XS::APItest::rng_fast_find($provider), 'XS can attach a registration');

{
    local ${^RNG} = $provider;
    is(rand(), 0.25, 'core calls the registered callback');
    XS::APItest::rng_fast_register($provider, 1);
    is(rand(), 0.75, 'replacement updates the installed cache');

    for my $mode (3, 4, 5) {
        eval { XS::APItest::rng_fast_register($provider, $mode) };
        like($@, qr/Invalid RNG fast descriptor/, "reject invalid descriptor $mode");
        is(rand(), 0.75, 'failed registration preserves the previous callback');
    }

    XS::APItest::rng_fast_unregister($provider);
    ok(!XS::APItest::rng_fast_find($provider), 'unregistration removes magic');
    is(rand(), 0, 'unregistration switches the installed provider to fallback');
    XS::APItest::rng_fast_unregister($provider);
    is(rand(), 0, 'unregistration is idempotent');

    XS::APItest::rng_fast_register($provider, 2);
    is(rand(), 0.25, 'validation accepts a draw');
    $$provider = 0;
    is(rand(), 0, 'validation can decline a draw');
    $$provider = 1;
    is(rand(), 0.25, 'validation is repeated on the next draw');
}

for my $value (42, \42, []) {
    eval { XS::APItest::rng_fast_register($value) };
    like($@, qr/must be an RNG::Provider object/, 'registration requires a blessed referent');
}

{
    my $first = RNG::FastTest::Aliasing->new;
    my $other = RNG::FastTest->new;
    $$other = 0;
    local $RNG::FastTest::Aliasing::replacement = $other;
    XS::APItest::rng_fast_register($first, 2);
    local ${^RNG} = $first;

    is(rand(), 0.25, 'the original referent passes validation');
    is(builtin::rand_bytes(1), "\0", 'the byte callback can assign its invocant');
    is(${^RNG}, $first, 'invocant assignment leaves the selected provider unchanged');
    is(rand(), 0.25, 'invocant assignment leaves the cached referent unchanged');

    $$first = 0;
    $$other = 1;
    is(rand(), 0, 'the validator can dispatch through the assigning callback');
    is(rand(), 0, 'validator fallback does not replace the cached referent');
}

{
    my $selected = RNG::FastTest::SeedCallback->new;
    XS::APItest::rng_fast_register($selected);
    local ${^RNG} = $selected;
    local $RNG::FastTest::SeedCallback::callback = sub { die "reseed failed\n" };

    eval { srand(5) };
    like($@, qr/reseed failed/, 'a provider seed exception propagates');
    ok(XS::APItest::rng_fast_find($selected), 'a rejected seed preserves registration');
    is(rand(), 0.25, 'a rejected seed preserves the native callback');

    my $during;
    $RNG::FastTest::SeedCallback::callback = sub { $during = rand(); $_[1] };
    srand(5);
    is($during, 0.25, 'a seed callback can make a reentrant native draw');

    $RNG::FastTest::SeedCallback::callback = sub {
        XS::APItest::rng_fast_register($_[0], 1);
        die "replacement failed\n";
    };
    eval { srand(5) };
    like($@, qr/replacement failed/, 'an exception after replacement propagates');
    is(rand(), 0.75, 'a seed exception preserves an explicit registration replacement');

    my $other = RNG::FastTest->new;
    XS::APItest::rng_fast_register($other);
    $RNG::FastTest::SeedCallback::callback = sub {
        ${^RNG} = $other;
        die "provider changed\n";
    };
    eval { srand(5) };
    like($@, qr/provider changed/, 'an exception after provider assignment propagates');
    is(${^RNG}, $other, 'a seed exception preserves the newly selected provider');
    is(rand(), 0.25, 'a seed exception preserves the newly selected callback');

    ${^RNG} = $selected;
    $RNG::FastTest::SeedCallback::callback = sub {
        XS::APItest::rng_fast_unregister($_[0]);
        die "registration removed\n";
    };
    eval { srand(5) };
    like($@, qr/registration removed/, 'an exception after unregistration propagates');
    is(rand(), 0, 'a seed exception does not restore a removed registration');
}

{
    my $selected = RNG::Drand48->new(42);
    my $control = RNG::Drand48->new(42);
    local ${^RNG} = $selected;
    is(rand(), $control->rand(), 'Drand48 starts on the expected native stream');
    my $saved = $selected->state;
    eval { srand(RNG::Seed->from_bytes('x')) };
    like($@, qr/must contain exactly 6 octets/, 'Drand48 rejects a short raw seed');
    is($selected->state, $saved, 'a rejected raw seed preserves Drand48 state');
    is(rand(), $control->rand(), 'a rejected raw seed preserves the Drand48 stream');
}

for my $class (qw(RNG::Drand48 RNG::PCG RNG::PCG::RXS_M_XS_64_64
                  RNG::PCG::XSL_RR_128_64_MCG RNG::PCG::XSL_RR_128_64_LCG
                  RNG::Wyrand RNG::Xoshiro)) {
    (my $file = "$class.pm") =~ s!::!/!g;
    require $file;
    my $unregistered = $class->new(42);
    XS::APItest::rng_fast_unregister($unregistered);
    eval { $unregistered->rand_bytes(4096) };
    like($@, qr/object does not contain a valid state/,
         "$class rejects byte requests after unregistration");
    $@ = '';

    my ($first_count, $last_count) = (0, 0);
    for my $attempt (1 .. 8) {
        eval { $unregistered->rand_bytes(4096) };
        $@ = '';
        $last_count = XS::APItest::sv_count();
        $first_count = $last_count if $attempt == 1;
    }
    is($last_count, $first_count, "$class failed byte requests do not leak SVs");
}

{
    local ${^RNG} = RNG::PCG->new(42);
    XS::APItest::rng_fast_register(${^RNG});
    is(rand(), 0.25, 'replacement frees owned native state and updates the cache');
    XS::APItest::rng_fast_unregister(${^RNG});
    eval { rand() };
    like($@, qr/object does not contain a valid state/,
         'unregistration removes state used by provider methods');
}

{
    no warnings 'once';
    local *RNG::FastTest::get_rand_U01_XS_func_addr =
        \&XS::APItest::rng_fast_fake_address;
    local *RNG::FastTest::get_rand_U01_XS_state_addr =
        \&XS::APItest::rng_fast_fake_address;
    local ${^RNG} = RNG::FastTest->new;
    is(rand(), 0, 'aliased XSUB address getters cannot forge registration');
}

SKIP: {
    eval { require threads; 1 } or skip 'Perl was not built with threads', 4;
    local ${^RNG} = $provider;
    my $thread = threads->create(sub {
        my $value = rand();
        XS::APItest::rng_fast_unregister(${^RNG});
        return [$value, rand()];
    });
    my $child = $thread->join;
    is(join(',', @$child), '0.25,0', 'a stateless registration is cloned independently');
    is(rand(), 0.25, 'child unregistration leaves the parent installed');

    XS::APItest::rng_fast_register($provider, 6);
    my $without_dup = threads->create(sub { rand() });
    is($without_dup->join, 0, 'native state without a dup callback is omitted from the clone');
    is(rand(), 0.25, 'the parent keeps its registration without a dup callback');
}

done_testing;
