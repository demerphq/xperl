use strict;
use warnings;
use JSON::PP ();
use Config;

my $mode = shift // 'after';
die 'expected before or after' unless $mode eq 'before' || $mode eq 'after';
my $samples = 7;
my $sink;

sub ordinary { return $_[0] + 1 }
my $factory = eval q{use generator; sub { gen { yield 1; yield 2 } }};
die $@ unless $factory;
my $capture_factory = eval q{
    use generator;
    sub { gen { 'capture' =~ /(.+)/; yield $1; yield $1 } }
};
die $@ unless $capture_factory;

my @cases = (
    ['ordinary_opcodes', 10_000_000, sub {
        my $value = 1;
        for (1 .. $_[0]) { $value += 3; $value ^= 7; $value &= 0xffff }
        $sink = $value;
    }],
    ['ordinary_calls', 5_000_000, sub {
        my $value = 1;
        for (1 .. $_[0]) { $value = ordinary($value) }
        $sink = $value;
    }],
    ['ordinary_closure_create_destroy', 1_000_000, sub {
        for (1 .. $_[0]) {
            my $value = $_;
            my $code = sub { $value };
            undef $code;
        }
    }],
    ['generator_create_destroy', 250_000, sub {
        for (1 .. $_[0]) { my $g = $factory->(); undef $g }
    }],
    ['generator_two_yields_destroy', 100_000, sub {
        for (1 .. $_[0]) {
            my $g = $factory->();
            $sink = $g->();
            $sink = $g->();
            undef $g;
        }
    }],
    ['generator_two_yields_with_capture', 100_000, sub {
        for (1 .. $_[0]) {
            my $g = $capture_factory->();
            $sink = $g->();
            $sink = $g->();
            undef $g;
        }
    }],
);

if ($mode eq 'after') {
    my $extra = eval q{
        use async;
        no warnings 'experimental::builtin';
        async sub bench_answer ($value) { return $value + 1 }
        async sub bench_awaits ($count) {
            my $value = 0;
            for (1 .. $count) { $value = await bench_answer($value) }
            return $value;
        }
        sub bench_nested ($task, $depth) {
            return $depth > 1 ? bench_nested($task, $depth - 1) : await $task;
        }
        async sub bench_deep_awaits ($count, $depth) {
            my $value = 0;
            for (1 .. $count) {
                $value = bench_nested(bench_answer($value), $depth);
            }
            return $value;
        }
        [
            ['task_create_destroy', 100_000, sub {
                for (1 .. $_[0]) { my $task = bench_answer(1); undef $task }
            }],
            ['task_run_immediate', 20_000, sub {
                for (1 .. $_[0]) { my $value = run(bench_answer(1)) }
            }],
            ['task_pending_await', 20_000, sub { run(bench_awaits($_[0])) }],
            ['task_pending_await_depth_8', 20_000, sub { run(bench_deep_awaits($_[0], 8)) }],
            ['task_pending_await_depth_32', 20_000, sub { run(bench_deep_awaits($_[0], 32)) }],
        ];
    };
    die $@ unless $extra;
    push @cases, @$extra;
}

my %results;
for my $case (@cases) {
    my ($name, $iterations, $run) = @$case;
    $run->($iterations);
    my @seconds;
    for (1 .. $samples) {
        my @start = times;
        $run->($iterations);
        my @end = times;
        push @seconds, $end[0] + $end[1] - $start[0] - $start[1];
    }
    my @sorted = sort {$a <=> $b} @seconds;
    $results{$name} = {
        iterations => $iterations,
        samples_seconds => \@seconds,
        median_ns => $sorted[int(@sorted / 2)] * 1e9 / $iterations,
    };
}

print JSON::PP->new->canonical->pretty->encode({
    mode => $mode, interpreter => "$^V", time_source => 'process CPU from times',
    config => {map { $_ => $Config{$_} } qw(useithreads usemultiplicity use64bitint ccflags optimize)},
    results => \%results,
});
