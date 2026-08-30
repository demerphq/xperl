#!./perl

use strict;
use warnings;
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

plan(tests => 75);

use generator;
no warnings 'experimental::builtin';

sub next_values {
    my ($generator, @args) = @_;
    my @values = $generator->(@args);
    return \@values;
}

sub is_deeply {
    my ($got, $expected, $name) = @_;
    is(join("\x1f", map { defined $_ ? $_ : "\x00" } @$got),
       join("\x1f", map { defined $_ ? $_ : "\x00" } @$expected), $name);
}

my $finite = generator_create {
    generator_yield 1;
    generator_yield 2;
};

ok(!generator_exhausted $finite, 'new generator is not exhausted');
is_deeply(next_values($finite), [ 1 ], 'first generator_yield');
ok(!generator_exhausted($finite), 'suspended generator is not exhausted');
is_deeply(next_values($finite), [ 2 ], 'second generator_yield');
is_deeply(next_values($finite), [], 'exhaustion returns an empty list');
ok(generator_exhausted $finite, 'completed generator is exhausted');
ok(generator_completed($finite), 'normally completed generator reports completion');
my $exhausted = eval { $finite->(); 1 };
ok(!$exhausted, 'exhaustion is permanent');
like($@, qr/cannot resume an exhausted generator/, 'exhaustion diagnostic');

my $undef = generator_create { generator_yield undef };
my $undef_values = next_values($undef);
is(scalar(@$undef_values), 1, 'undef is still one yielded value');
ok(!defined($undef_values->[0]), 'yielded undef is preserved');

my $n = 10;
my $closure = generator_create { generator_yield $n++; generator_yield $n++ };
is_deeply(next_values($closure), [ 10 ], 'generator closes over lexical state');
is_deeply(next_values($closure), [ 11 ], 'lexical state survives suspension');

my $loop = generator_create {
    for my $value (1 .. 3) {
        generator_yield $value;
    }
};
is_deeply(next_values($loop), [ 1 ], 'loop generator_yield one');
is_deeply(next_values($loop), [ 2 ], 'loop generator_yield two');
is_deeply(next_values($loop), [ 3 ], 'loop generator_yield three');
is_deeply(next_values($loop), [], 'loop generator exhausts');

my $inner_eval = generator_create {
    my $ignored = eval { die "inner failure\n" };
    generator_yield $@;
};
like($inner_eval->(), qr/inner failure/, 'inner eval catches its failure');
is_deeply(next_values($inner_eval), [], 'inner-eval generator exhausts');

my $failed = generator_create {
    generator_yield 'before failure';
    die "generator failure\n";
};
ok(!generator_exhausted $failed, 'failed generator is not initially exhausted');
ok(!generator_completed($failed), 'failed generator is not initially completed');
ok(!generator_failed($failed), 'failed generator is not initially failed');
is_deeply(next_values($failed), [ 'before failure' ], 'failure follows a yield');
my ($failure, $failure_error, $resumed_failed, $resumed_failed_error);
{
    local $@;
    $failure = eval { $failed->(); 1 };
    $failure_error = $@;
    $resumed_failed = eval { $failed->(); 1 };
    $resumed_failed_error = $@;
}
ok(!$failure, 'failure is reported by resume');
like($failure_error, qr/generator failure/, 'original failure is rethrown');
ok(generator_exhausted($failed), 'failed generator is terminal');
ok(!generator_completed($failed), 'failed generator is not completed');
ok(generator_failed($failed), 'failed generator reports failure');
ok(!$resumed_failed, 'failed generator cannot be resumed');
like($resumed_failed_error, qr/cannot resume a failed generator/, 'failed-resume diagnostic');

my $args = generator_create {
    my ($first, $second) = @_;
    my ($next, @rest) = generator_yield($first + $second);
    return ($next, @rest);
};
is_deeply(next_values($args, 2, 3), [ 5 ], 'initial arguments reach @_');
is_deeply(next_values($args, 7, 8), [ 7, 8 ],
    'resume arguments are returned by generator_yield');
ok(generator_exhausted($args), 'return marks an argument generator exhausted');

my $scalar_resume = generator_create {
    my $count = generator_yield 1;
    return $count;
};
is($scalar_resume->(), 1, 'initial scalar yield remains available');
is($scalar_resume->(10, 20), 10,
    'scalar generator_yield returns the first resume argument');

my $parameterized = generator_create ($x, $y, $z) {
    my $sum = generator_yield($x + $y);
    return $z * $sum;
};
my $parameterized_sum = $parameterized->(1, 2, 3);
is($parameterized_sum, 3, 'scalar generator call returns its first yield');
cmp_ok(abs($parameterized->(sqrt($parameterized_sum)) - 5.19615242270663), '<',
    1e-12, 'scalar generator resume returns its first argument');

my $empty_yield = generator_create {
    generator_yield ();
    return 9;
};
is_deeply(next_values($empty_yield), [], 'empty list is a real yield');
ok(!generator_exhausted($empty_yield), 'empty yield does not exhaust');
is_deeply(next_values($empty_yield), [ 9 ], 'return follows an empty yield');

my $return_list = generator_create {
    generator_yield 1;
    return (2, 3);
};
is_deeply(next_values($return_list), [ 1 ], 'yield precedes list return');
is_deeply(next_values($return_list), [ 2, 3 ],
    'list return values are returned on completion');

my $signature_args = generator_create ($x, $y) {
    my $sum = generator_yield($x + $y);
    return $sum;
};
is($signature_args->(4, 5), 9, 'generator signature binds initial arguments');
is($signature_args->(12), 12,
    'signature bindings survive while resume args are supplied');

my $scalar = generator_create { generator_yield 42 };
is(scalar($scalar->()), 42, 'scalar context returns the yielded value');

my $list_context = generator_create {
    generator_yield (wantarray ? 'list' : 'scalar');
};
is_deeply(next_values($list_context), [ 'list' ],
    'generator body sees list context');
my $scalar_context = generator_create {
    generator_yield (wantarray ? 'list' : 'scalar');
};
is($scalar_context->(), 'scalar', 'generator body sees scalar context');

my $list_resume_context = generator_create {
    generator_yield 1;
    return wantarray ? 'list' : 'scalar';
};
is_deeply(next_values($list_resume_context), [ 1 ],
    'first generator call supplies list context');
is_deeply(next_values($list_resume_context), [ 'list' ],
    'list context is supplied when resuming after a yield');

my $scalar_resume_context = generator_create {
    generator_yield 1;
    return wantarray ? 'list' : 'scalar';
};
is($scalar_resume_context->(), 1,
    'first scalar generator call supplies scalar context');
is($scalar_resume_context->(), 'scalar',
    'scalar context is supplied when resuming after a yield');

my $void_resume_context;
my $void_context = generator_create {
    generator_yield 1;
    $void_resume_context = !defined(wantarray) ? 'void'
                         : wantarray ? 'list' : 'scalar';
};
$void_context->();
$void_context->();
is($void_resume_context, 'void',
    'void context is supplied when resuming after a yield');

my $running_one = generator_create { generator_yield 1 };
my $running_two = generator_create { generator_yield 2 };
my @running = generator_running($running_one, $finite, $running_two);
is(scalar @running, 2, 'generator_running filters terminal generators');
is($running[0], $running_one, 'generator_running keeps the first active generator');
is($running[1], $running_two, 'generator_running keeps the second active generator');
my $empty_yield_running = generator_create {
    generator_yield ();
    generator_yield 9;
};
is_deeply(next_values($empty_yield_running), [],
    'fresh generator produces an empty yield');
is_deeply([ generator_running($empty_yield_running) ], [ $empty_yield_running ],
    'generator_running keeps a generator after an empty yield');
is_deeply([ generator_running($failed) ], [],
    'generator_running omits a failed generator');

my $saved_input_separator = $/;
my $localized = generator_create {
    local $/ = 'generator separator';
    generator_yield $/;
    generator_yield $/;
};
    is_deeply(next_values($localized), [ 'generator separator' ],
    'localization survives the first suspension');
is_deeply(next_values($localized), [ 'generator separator' ],
    'localization survives the second suspension');
is_deeply(next_values($localized), [], 'localized generator exhausts');
is($/, $saved_input_separator, 'localization is restored at exhaustion');

my $reentrant;
$reentrant = generator_create { generator_yield $reentrant->() };
my ($reentered, $reentered_error);
{
    local $@;
    $reentered = eval { $reentrant->(); 1 };
    $reentered_error = $@;
}
ok(!$reentered, 're-entrant resume is rejected');
like($reentered_error, qr/generator has no suspended continuation/,
    're-entrant resume diagnostic');
$reentrant = undef;

my $nested_inner = generator_create { generator_yield 10; generator_yield 20 };
my $nested_outer = generator_create {
    generator_yield $nested_inner->();
    generator_yield $nested_inner->();
};
is_deeply(next_values($nested_outer), [ 10 ],
    'nested generator resumes its inner generator');
is_deeply(next_values($nested_outer), [ 20 ],
    'nested generator preserves the inner continuation');
is_deeply(next_values($nested_outer), [], 'nested generator exhausts');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'generator_yield 1'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected outside a generator');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'sub ordinary_generator_test { generator_yield 1 }'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected in an ordinary sub');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'sort { generator_yield 1 } 1, 2'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected in sort callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'map { generator_yield 1 } 1, 2'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected in map callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'grep { generator_yield 1 } 1, 2'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected in grep callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'q[a] =~ /(?{ generator_yield 1 })/'),
    qr/generator_yield outside a generator_create/, 'generator_yield is rejected in regex callbacks');

is(runperl(switches => ['-Mfeature=generator', '-Mbuiltin=weaken'],
           prog => 'package Generator::Cleanup; sub DESTROY { }'
                . ' package main; my $weak;'
                . ' my $generator = generator_create { my $object = bless {},'
                . ' q[Generator::Cleanup]; $weak = $object; weaken($weak);'
                . ' generator_yield 1 }; $generator->(); undef $generator;'
                . ' print defined($weak) ? q[live] : q[destroyed]'),
   'destroyed', 'dropping a suspended generator releases its pad');

like(runperl(stderr => 1,
             prog => 'my $not_a_generator = generator_create { 1 }'),
    qr/Can't locate object method "generator_create"/,
    'generator syntax remains feature gated');

undef $finite;
undef $undef;
undef $closure;
undef $loop;
undef $inner_eval;
undef $failed;
undef $args;
undef $scalar;
undef $list_context;
undef $scalar_context;
undef $localized;
undef $nested_outer;
undef $nested_inner;
undef $undef_values;
undef $reentered;
undef $exhausted;
undef $failure;
undef $resumed_failed;
undef $saved_input_separator;
undef $n;
undef $@;
