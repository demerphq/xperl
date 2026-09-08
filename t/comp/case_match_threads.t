#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use feature 'case_match';

eval { require threads; threads->create(sub { 1 })->join };
if ($@) {
    skip_all('threads are not available');
}

plan(5);

sub run_case_in_thread {
    my ($subject) = @_;
    my $result = do {
        case ($subject) {
            match ([ 1, $value ]) { $value }
            match (_) { undef }
        }
    };
    return defined($result) ? $result : 'undef';
}

my @threads = map threads->create(\&run_case_in_thread, $_),
    [ 1, 2 ], [ 1, 9 ], [ 2, 3 ];
my @results = map $_->join, @threads;
is(join(',', @results), '2,9,undef',
   'cloned case patterns keep independent thread state');

my $nested = threads->create(sub {
    my ($subject) = @_;
    case ($subject) {
        match ([ 1, $outer ]) {
            case ($outer) {
                match (2) { 'nested' }
                match (_) { 'wrong' }
            }
        }
        match (_) { 'wrong' }
    }
}, [ 1, 2 ]);
is($nested->join, 'nested', 'nested cases work in a cloned thread');

my $exception = threads->create(sub {
    eval { case (die 'thread subject failure') { match (_) { 1 } } };
    my $error = $@;
    my $after = do { case (2) { match (2) { 'after' } } };
    return $error =~ /thread subject failure/ && $after eq 'after';
});
ok($exception->join, 'thread exceptions restore case state');

my $void = threads->create(sub {
    my $seen = 0;
    case (1) { match (1) { $seen++ } };
    return $seen;
});
is($void->join, 1, 'case clauses execute once in a cloned thread');

my $separate = threads->create(sub {
    my $subject = [ 1, 4 ];
    my $result = do { case ($subject) { match ([ 1, $item ]) { $item } } };
    $subject->[1] = 8;
    return $result == 4 && $subject->[1] == 8;
});
ok($separate->join, 'thread-local subjects remain mutable after matching');
