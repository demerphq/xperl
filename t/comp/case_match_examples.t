#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
}

use Test::More tests => 4;
use feature 'case_match';
use builtin qw(true false);

# This is one small program, rather than a collection of isolated parser
# checks.  One case classifies a mixed stream whose values have different
# shapes.  More-specific clauses come before broader open shapes.
my $showcase_pin = '__not_in_examples__';

sub classify {
    my ($value) = @_;

    case ($value as $subject) with ($showcase_pin) {
        match ($showcase_pin)                   { 'pinned value' }
        match (undef)                            { 'undefined' }
        match (0)                                { 'zero' }
        match (42)                               { 'the number 42' }
        match ('plain')                          { 'the string plain' }
        match ('prefix_' . $inner . '_suffix')  { "inside <$inner>" }
        match ('prefix_' . $suffix)              { "suffix <$suffix>" }
        match ($prefix . '_suffix')              { "prefix <$prefix>" }
        match ([ 'point', $x, $y ])              { "point ($x,$y)" }
        match ([ { name => $first }, { name => $second } ])
                                                    { "nested <$first/$second>" }
        match ([ ..., 'foo_' . $inside . '_bar', ... ])
                                                    { "floating <$inside>" }
        match ([ 'pair', $head, @tail:1 ])       { "pair <$head;" . join(',', @tail) . '>' }
        match ([ { kind => 'point', x => $x, y => $y }, ... ])
                                                    { "point record ($x,$y)" }
        match ([ 0, ... ])                        { 'starts <0>' }
        match ([ ..., $last ])                    { "ends <$last>" }
        match ({ kind => 'point', x => $x, y => $y })
                                                    { "point hash ($x,$y)" }
        match ({ status => 'ok', code => $code })
                                                    { "exact status <$code>" }
        match ({ status => 'ok', code => $code, ... })
                                                    { "open status <$code>" }
        match ({ status => $status, ... })            { "any status <$status>" }
        match ({ kind => 'user', name => $name, ... })
                                                    { "user <$name>" }
        match (ObjectVal($object))                { 'object ' . ref($object) }
        match (RefVal($reference))                { 'reference ' . ref($reference) }
        match (ScalarVal($scalar) if $scalar eq 'plain scalar')
                                                    { 'plain scalar' }
        match (_)                                 { "unknown <$subject>" }
    }
}

my @values = (
    undef,
    0,
    42,
    'plain',
    '__not_in_examples__',
    'prefix_middle_suffix',
    'prefix_tail',
    'head_suffix',
    [ 'point', 3, 4 ],
    [ { name => 'first' }, { name => 'second' } ],
    [ 'before', 'foo_middle_bar', 'after' ],
    [ 'pair', 'left', 'middle', 'right' ],
    [ 0, 8, 9 ],
    [ 'tail', 8, 9 ],
    [ { kind => 'point', x => 8, y => 13 }, { extra => 1 } ],
        { kind => 'point', x => 3, y => 4 },
        { status => 'ok', code => 200 },
        { status => 'ok', code => 201, detail => 'created' },
        { status => 'queued', id => 10 },
        { kind => 'user', name => 'Ada', active => true },
    bless({}, 'Example::Widget'),
    \ 'an ordinary scalar reference',
    'plain scalar',
    'something else',
);

is_deeply(
    [ map { classify($_) } @values ],
    [
        'undefined',
        'zero',
        'the number 42',
        'the string plain',
        'pinned value',
        'inside <middle>',
        'suffix <tail>',
        'prefix <head>',
        'point (3,4)',
        'nested <first/second>',
        'floating <middle>',
        'pair <left;middle,right>',
        'starts <0>',
        'ends <9>',
        'point record (8,13)',
        'point hash (3,4)',
        'exact status <200>',
        'open status <201>',
        'any status <queued>',
        'user <Ada>',
        'object Example::Widget',
        'reference SCALAR',
        'plain scalar',
        'unknown <something else>',
    ],
    'one case classifies a mixed stream of scalar and structured values',
);

is_deeply(
    [
        do { case (1) { match (true) { 'true' } match (false) { 'false' } } },
        do { case (0) { match (true) { 'true' } match (false) { 'false' } } },
    ],
    [ 'true', 'false' ],
    'true and false use Perl truth-value semantics',
);

is_deeply(
    [
        do { case (IntVal '12')    { match (12)   { 'integer' } } },
        do { case (FloatVal '2.5') { match (2.5)  { 'float' } } },
        do { case (StrVal 12)      { match ('12') { 'string' } } },
    ],
    [ 'integer', 'float', 'string' ],
    'IntVal, FloatVal, and StrVal coerce the subject before matching',
);

ok(!defined(do { case ('not listed') { match (1) { 'wrong' } } }),
    'a case with no matching clause returns undef');
