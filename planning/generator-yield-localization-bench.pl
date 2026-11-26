use v5.40;
use generator;
use Config;
use JSON::PP;
use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);

# CPU time keeps concurrent builds from being charged to a suspension.
# This benchmark uses Linux's process CPU clock on the same build settings.

my $label = shift // 'after';
my $iterations = 10_000;
my $samples = 9;
our $plain = 7;
sub ordinary { return 7 }
my @results;

sub measure {
    my ($name, $prepare, $run, $finish) = @_;
    my @seconds;
    for my $round (0 .. $samples) {
        my $state = $prepare->();
        my $start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
        $run->($state);
        my $elapsed = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $start;
        push @seconds, $elapsed if $round;
        $finish->($state);
    }
    my @sorted = sort { $a <=> $b } @seconds;
    push @results, {
        case => $name, samples_seconds => \@seconds,
        median_ns_per_operation => $sorted[int(@sorted / 2)] * 1e9 / $iterations,
    };
}

measure('ordinary_read', sub {}, sub {
    my $sum = 0;
    $sum += $plain for 1 .. $iterations;
    die unless $sum == 7 * $iterations;
}, sub {});
measure('ordinary_call', sub {}, sub {
    my $sum = 0;
    $sum += ordinary() for 1 .. $iterations;
    die unless $sum == 7 * $iterations;
}, sub {});
measure('ordinary_local', sub {}, sub {
    for (1 .. $iterations) {
        local $plain = 8;
        die unless $plain == 8;
    }
}, sub {});

for my $kind (qw(scalar array hash)) {
    for my $count (0, 8, 32, 64) {
        next if !$count && $kind ne 'scalar';
        my $source = 'sub { gen {';
        for my $i (1 .. $count) {
            my $sigil = $kind eq 'scalar' ? '$' : $kind eq 'array' ? '@' : '%';
            my $initial = $kind eq 'hash' ? '(key => 1)' : '(1)';
            $source .= "local ${sigil}AggregateBench::slot_$i = $initial;\n";
        }
        $source .= 'while (!(yield 1)) {} return 1; } }';
        my $factory = eval $source;
        die $@ unless $factory;
        measure("switch_${kind}_$count", sub {
            my $g = $factory->();
            my $first = $g->();
            die unless $first == 1;
            return $g;
        }, sub {
            my ($g) = @_;
            my $sum = 0;
            $sum += $g->() for 1 .. $iterations;
            die unless $sum == $iterations;
        }, sub {
            my ($g) = @_;
            my $last = $g->(1);
            die unless $last == 1;
        });
    }
}
print JSON::PP->new->canonical->pretty->encode({
    label => $label, iterations => $iterations, samples => $samples,
    optimize => $Config{optimize}, ccflags => $Config{ccflags},
    useithreads => $Config{useithreads}, results => \@results,
    clock => 'CLOCK_PROCESS_CPUTIME_ID',
});
