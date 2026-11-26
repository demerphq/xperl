#!./perl
# Run from the checkout root, with 'before' to omit the new loop/signal cases.
use strict;
use warnings;
use generator;
use Config;
use JSON::PP;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my $mode = shift // 'after';
my $iterations = 50_000;
my $samples = 9;
our ($word, $iterator) = (7, 0);
sub ordinary { return 7 }
my %hash = (key => 7);
my @cases = (
    ['ordinary_call', sub {
        my $sum = 0;
        $sum += ordinary() for 1 .. $iterations;
        die unless $sum == 7 * $iterations;
    }],
    ['ordinary_read', sub {
        my $sum = 0;
        $sum += $word for 1 .. $iterations;
        die unless $sum == 7 * $iterations;
    }],
    ['ordinary_local', sub {
        for (1 .. $iterations) {
            local $word = 8;
            die unless $word == 8;
        }
    }],
    ['ordinary_hash_read', sub {
        my $sum = 0;
        $sum += $hash{key} for 1 .. $iterations;
        die unless $sum == 7 * $iterations;
    }],
    ['generator_create_destroy', sub {
        for (1 .. $iterations) {
            my $g = gen { return 1 };
            die unless $g;
        }
    }],
);

my $empty = gen { while (1) { yield 1 } };
$empty->();
push @cases, ['switch_empty', sub {
    my $sum = 0;
    $sum += $empty->() for 1 .. $iterations;
    die unless $sum == $iterations;
}];

if ($mode eq 'after') {
    my $loop = gen { for $iterator (1 .. 1_000_000) { yield $iterator } };
    $loop->();
    push @cases, ['switch_package_foreach', sub { $loop->() for 1 .. $iterations }];
    if ($Config{d_sigaction} && $Config{d_sigprocmask} && exists $SIG{WINCH}) {
        my $signal = gen {
            local $SIG{WINCH} = sub {};
            while (1) { yield 1 }
        };
        $signal->();
        push @cases, ['switch_one_signal_local', sub { $signal->() for 1 .. $iterations }];
    }
}

my @results;
for my $case (@cases) {
    my ($name, $run) = @$case;
    my @elapsed;
    for my $round (0 .. $samples) {
        my $start = clock_gettime(CLOCK_MONOTONIC);
        $run->();
        push @elapsed, clock_gettime(CLOCK_MONOTONIC) - $start if $round;
    }
    my @ordered = sort { $a <=> $b } @elapsed;
    push @results, {
        case => $name,
        samples_seconds => \@elapsed,
        median_ns_per_operation => $ordered[int(@ordered / 2)] * 1e9 / $iterations,
    };
}
print JSON::PP->new->canonical->pretty->encode({
    mode => $mode, iterations => $iterations, samples => $samples,
    optimize => $Config{optimize}, ccflags => $Config{ccflags},
    useithreads => $Config{useithreads}, results => \@results,
});
