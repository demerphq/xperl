#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
}

use Test::More tests => 8;
use feature 'case_match';
use builtin qw(true false);

# This is intentionally written as a small program, rather than as a list of
# isolated parser checks.  It shows how a case statement can classify a stream
# of values whose shapes are not all alike.
sub classify {
    my ($value) = @_;

    case ($value) {
        match (undef)                         { 'undefined' }
        match (0)                              { 'zero' }
        match (42)                             { 'the number 42' }
        match ('plain')                        { 'the string plain' }
        match ('error:' . $message)            { "error <$message>" }
        match ('tag:' . $tag)                  { "tag <$tag>" }
        match ([ 'point', $x, $y ])            { "point ($x,$y)" }
        match ([ 'pair', $head, @tail:1 ])     { "pair ($head;" . join(',', @tail) . ')' }
        match ([ { kind => 'point', x => $x, y => $y }, ... ])
                                                { "point record ($x,$y)" }
        match ({ kind => 'user', name => $name, ... })
                                                { "user <$name>" }
        match (ObjectVal($object))             { 'object ' . ref($object) }
        match (RefVal($reference))              { 'reference ' . ref($reference) }
        match (ScalarVal($scalar))             { 'other scalar' }
        match (_)                              { 'unknown' }
    }
}

my @values = (
    undef,
    0,
    42,
    'plain',
    'error: disk full',
    'tag:ready',
    [ 'point', 3, 4 ],
    [ 'pair', 'left', 'middle', 'right' ],
    [ { kind => 'point', x => 8, y => 13 }, { extra => 1 } ],
    { kind => 'user', name => 'Ada', active => true },
    bless({}, 'Example::Widget'),
    [ 'an', 'ordinary', 'reference' ],
    'something else',
);

is_deeply(
    [ map { classify($_) } @values ],
    [
        'undefined',
        'zero',
        'the number 42',
        'the string plain',
    'error < disk full>',
        'tag <ready>',
        'point (3,4)',
        'pair (left;middle,right)',
        'point record (8,13)',
        'user <Ada>',
        'object Example::Widget',
        'reference ARRAY',
        'other scalar',
    ],
    'one case classifies a mixed stream of scalar and structured values',
);

sub boolean_label {
    my ($value) = @_;
    case ($value) {
        match (true)  { 'true' }
        match (false) { 'false' }
    }
}

is_deeply(
    [ boolean_label(1), boolean_label(0) ],
    [ 'true', 'false' ],
    'true and false use Perl truth-value semantics',
);

sub typed_subjects {
    my @answer;
    case (IntVal '12')    { match (12)   { push @answer, 'integer' } }
    case (FloatVal '2.5') { match (2.5)  { push @answer, 'float' } }
    case (StrVal 12)      { match ('12') { push @answer, 'string' } }
    return \@answer;
}

is_deeply(
    typed_subjects(),
    [ 'integer', 'float', 'string' ],
    'IntVal, FloatVal, and StrVal coerce the subject before matching',
);

my $wanted = 'ok';
my $record = { status => 'ok', value => 7, extra => 'kept' };
my $record_result = do {
    case ($record as $subject) with ($wanted) {
        match ({ status => $wanted, value => $value, ... } if $value > 0) {
            "$subject->{status}:$value"
        }
        match (_) { 'not accepted' }
    }
};

is(
    $record_result,
    'ok:7',
    'case as, with pins, open hashes, captures, and guards work together',
);

my $negative_record = { status => 'ok', value => -1 };
is(
    do {
        case ($negative_record) {
            match ({ status => 'ok', value => $value, ... } if $value > 0) { 'accepted' }
            match (_) { 'rejected by guard' }
        }
    },
    'rejected by guard',
    'a false guard rejects the clause and selects the wildcard',
);

my $nested = [ { name => 'first' }, { name => 'second' } ];
is(
    do {
        case ($nested) {
            match ([ { name => $first }, { name => $second } ]) { "$first/$second" }
        }
    },
    'first/second',
    'nested data shapes bind values from more than one level',
);

my $no_match = do {
    case ('not listed') {
        match (1) { 'wrong' }
    }
};
ok(!defined($no_match), 'a case with no matching clause returns undef');

my $wildcard = do {
    case ({ anything => 1 }) {
        match ({ expected => 2 }) { 'wrong' }
        match (_) { 'fallback' }
    }
};
is($wildcard, 'fallback', 'the wildcard provides a final default clause');
