use v5.40;
use generator;
use Config;
use JSON::PP;
use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);

my $label = shift // 'after';
my $iterations = 10_000;
my $samples = 9;
my @results;
for my $count (0, 1, 8, 32) {
    my $source = 'sub { gen {' . (q{local $_ = 'topic';} x $count)
        . 'while (!(yield 1)) {} return 1; } }';
    my $factory = eval $source;
    die $@ unless $factory;
    my @seconds;
    for my $sample (0 .. $samples) {
        my $g = $factory->();
        my $ready = $g->();
        die unless $ready == 1;
        my $start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
        my $sum = 0;
        $sum += $g->() for 1 .. $iterations;
        my $elapsed = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $start;
        die unless $sum == $iterations;
        my $done = $g->(1);
        die unless $done == 1;
        push @seconds, $elapsed if $sample;
    }
    my @sorted = sort {$a <=> $b} @seconds;
    push @results, {
        topic_locals => $count, samples_cpu_seconds => \@seconds,
        median_ns_per_resume_yield => $sorted[int(@sorted / 2)] * 1e9 / $iterations,
    };
}
print JSON::PP->new->canonical->pretty->encode({
    label => $label, iterations => $iterations, samples => $samples,
    clock => 'CLOCK_PROCESS_CPUTIME_ID', optimize => $Config{optimize},
    cpu => $ENV{XPERL_TOPIC_BENCH_CPU},
    ccflags => $Config{ccflags}, useithreads => $Config{useithreads},
    results => \@results,
});
