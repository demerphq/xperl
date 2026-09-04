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
my ($showcase_status, $showcase_code) = ('ok', 200);

sub classify {
    my ($value) = @_;

    case ($value as $subject) with ($showcase_pin, $showcase_status, $showcase_code) {
        # Scalar shapes and scalar concatenation.
        match ($showcase_pin)                 { 'pinned value' }
        match (undef)                         { 'undefined' }
        match (0)                             { 'zero' }
        match (42 if $subject > 40)           { 'guard accepted 42' }
        match (42)                            { 'the number 42' }
        match ('guarded' if $subject eq 'not guarded')
                                              { 'guard should not pass' }
        match ('guarded')                     { 'guard fell through' }
        match ('plain')                       { 'the string plain' }
        match (/^user: (?<regex_user>\w+)$/)  { "regex <$regex_user/$1/$+{regex_user}>" }
        match ('prefix_' . $inner . '_suffix'){ "inside <$inner>" }
        match ('prefix_' . $suffix)           { "suffix <$suffix>" }
        match ($prefix . '_suffix')           { "prefix <$prefix>" }

        # Nested arrays, open arrays, and array slurps.
        match ([ 'point', $x, $y ])           { "point ($x,$y)" }
        match ([ { name => $first },
                 { name => $second } ])       { "nested <$first/$second>" }
        match ([ ..., 'foo_' . $inside . '_bar', ... ])
                                              { "floating <$inside>" }
        match ([ 'pair', $head, @tail:1 ])    { "pair <$head;" . join(',', @tail) . '>' }
        match ([ { kind => 'point', x => $x, y => $y }, ... ])
                                              { "point record ($x,$y)" }
        match ([ 0, ... ])
                                              { 'array starts with <0>' }
        match ([ ..., $last ])                { "ends <\$last=$last>" }

        # Hash shapes, including pinned and open hashes.
        match ({ kind => 'point',
                 x => $x, y => $y })          { "point hash ($x,$y)" }
        match ({ status => $showcase_status,
                 code => $showcase_code })    { 'pinned status' }
        match ({ status => 'ok',
                 code => $code, ... })        { "open status <$code>" }
        match ({ status => $status, ... })    { "any status <$status>" }
        match ({ kind => 'user',
                 name => $name, ... })        { "user <$name>" }

        # Type criteria, guards, references, and the wildcard default.
        match (ObjectVal($object))            { 'object ' . ref($object) }
        match (RefVal($reference))            { 'reference ' . ref($reference) }
        match (ScalarVal($scalar)
               if $scalar eq 'plain scalar')  { 'plain scalar' }
        match (_)                             { "unknown <$subject>" }
    }
}

my @values = (
    undef,
    0,
    42,
    'guarded',
    'plain',
    'user: Ada',
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
        'guard accepted 42',
        'guard fell through',
        'the string plain',
        'regex <Ada/Ada/Ada>',
        'pinned value',
        'inside <middle>',
        'suffix <tail>',
        'prefix <head>',
        'point (3,4)',
        'nested <first/second>',
        'floating <middle>',
        'pair <left;middle,right>',
        'array starts with <0>',
        'ends <$last=9>',
        'point record (8,13)',
        'point hash (3,4)',
        'pinned status',
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
