#!./perl

# Tests for ${^RE_BUDGET}, which limits the work that regex compilation and
# matching may do, and ${^RE_RESTRICT}, which limits patterns to the
# constructs whose cost that budget accounts for.

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use Config;

my $exhausted = qr/\ARegexp matching budget exhausted at /;

# A match that takes exponential time, so that any budget stops it.
my $slow_subject = ('a' x 40) . 'b';
my $slow_re = qr/^(a+)+\1?$/;

# Run a match under a budget.  Returns the result ('match', 'no match' or
# the exception) and the number of units used.  The budget is local to the
# block, so it is lifted again before the caller looks at anything.
sub bounded {
    my ($budget, $subject, $re) = @_;
    my $left;
    my $result = eval {
        local ${^RE_BUDGET} = $budget;
        my $matched = $subject =~ $re ? 'match' : 'no match';
        $left = ${^RE_BUDGET};
        $matched;
    };
    return ($@, $budget) unless defined $result;
    return ($result, $budget - $left);
}

# The variables themselves.
{
    is(${^RE_BUDGET}, undef, 'no budget by default');
    is(${^RE_RESTRICT}, 0, 'no restriction by default');
    {
        local ${^RE_BUDGET} = 1000;
        is(${^RE_BUDGET}, 1000, 'budget can be set');
        ok('abc' =~ /b/, 'matching works under a budget');
        cmp_ok(${^RE_BUDGET}, '<', 1000, 'matching uses the budget');
        cmp_ok(${^RE_BUDGET}, '>', 900, 'a small match uses little of it');
        ${^RE_BUDGET} = -5;
        is(${^RE_BUDGET}, undef, 'a negative value lifts the budget');
        ${^RE_BUDGET} = 7;
        ${^RE_BUDGET} = undef;
        is(${^RE_BUDGET}, undef, 'undef lifts the budget');
    }
    is(${^RE_BUDGET}, undef, 'budget is restored on scope exit');
    {
        local ${^RE_RESTRICT} = 'yes';
        is(${^RE_RESTRICT}, 1, 'restriction is a boolean');
    }
    is(${^RE_RESTRICT}, 0, 'restriction is restored on scope exit');
}

# Patterns that take exponential time in a backtracking matcher.  Without a
# budget each of these would run for far longer than the test suite does.
{
    my $long = 'a' x 40;
    my @blowups = (
        [ 'nested quantifier with a backreference',
          $long . 'b', qr/^(a+)+\1?$/ ],
        [ 'alternation of overlapping repeats with a backreference',
          $long . 'b', qr/^(a|aa)+\1?$/ ],
        [ 'nested quantifiers around a conditional',
          $long . 'b', qr/^(?:(a)|a(?(1)a|a))+$/ ],
        [ 'repeated lookahead capture',
          $long . 'b', qr/^(?:(?=(a+))a+?\1?)+c/ ],
    );
    for my $test (@blowups) {
        my ($name, $subject, $re) = @$test;
        watchdog(60);
        my ($result, $used) = bounded(200_000, $subject, $re);
        watchdog(0);
        like($result, $exhausted, "$name: stopped by the budget");
        is(${^RE_BUDGET}, undef, "$name: budget lifted afterwards");
        ok('xay' =~ /a/ && $& eq 'a', "$name: matching works afterwards");
    }
}

# Matches that succeed or fail normally are not affected, and what they
# use is repeatable.
{
    my @ordinary = (
        [ 'literal',           'hello world',            qr/wor/,          'match' ],
        [ 'class and repeat',  'key = value',            qr/^(\w+)\s*=\s*(\w+)$/, 'match' ],
        [ 'no match',          'hello world',            qr/^\d+$/,        'no match' ],
        [ 'alternation',       'the quick brown fox',    qr/\b(?:cat|dog|fox)\b/, 'match' ],
        [ 'case-insensitive',  "STRASSE",                qr/stra(?:ss|\xdf)e/i, 'match' ],
        [ 'backreference',     'abcabc',                 qr/^(\w+)\1$/,    'match' ],
        [ 'lookbehind',        'price: $42',             qr/(?<=\$)\d+/,   'match' ],
    );
    for my $test (@ordinary) {
        my ($name, $subject, $re, $want) = @$test;
        my ($result, $used) = bounded(10_000, $subject, $re);
        is($result, $want, "$name: result under a budget");
        my ($again, $used_again) = bounded(10_000, $subject, $re);
        is($used_again, $used, "$name: the same match costs the same again");
        cmp_ok($used, '>', 0, "$name: the match was charged");
    }
}

# Exhaustion leaves the budget at zero, so nothing more runs under it.
{
    my @seen;
    my $ok = eval {
        local ${^RE_BUDGET} = 2000;
        push @seen, 'before';
        $slow_subject =~ $slow_re;
        push @seen, 'not reached';
        1;
    };
    ok(!$ok, 'small budget is exhausted');
    is("@seen", 'before', 'the exception leaves the block');

    my @steps;
    {
        local ${^RE_BUDGET} = 2000;
        eval { $slow_subject =~ $slow_re };
        push @steps, ${^RE_BUDGET};
        eval { 'a' =~ /a/ };
        push @steps, $@ ? 'died' : 'ran';
        ${^RE_BUDGET} = 100;
        eval { 'a' =~ /a/ };
        push @steps, $@ ? 'died' : 'ran';
    }
    is("@steps", '0 died ran',
       'an exhausted budget stops later matches until it is renewed');
}

# The budget is shared by everything in its dynamic scope.
{
    my $subject = 'ab ' x 200;
    my ($count, $died) = (0, 0);
    {
        local ${^RE_BUDGET} = 400;
        eval { $count++ while $subject =~ /\w+/g; 1 } or $died = 1;
    }
    ok($died, 'a //g loop runs out of a budget that one match would not');
    cmp_ok($count, '>', 2, 'some of the matches ran first');
    cmp_ok($count, '<', 200, 'not all of them did');

    my $copy = $subject;
    my $changed = eval { local ${^RE_BUDGET} = 400; $copy =~ s/\w+/x/g; 1 };
    ok(!$changed, 's///g runs out of the same budget');
    is($copy, $subject, 'the interrupted s///g left its target alone');

    my @parts = eval { local ${^RE_BUDGET} = 400; split /b\s/, $subject };
    like($@, $exhausted, 'split runs out of the same budget');

    sub helper { return $_[0] =~ $slow_re }
    my $r = eval { local ${^RE_BUDGET} = 2000; helper($slow_subject) };
    like($@, $exhausted, 'the budget applies to matches in called code');
}

# Work that depends on the length of the subject is charged for, whichever
# part of the engine does it.
{
    my $big = 'x' x 400_000;
    my @scans = (
        [ 'simple repeat',               qr/^.*y/s ],
        [ 'repeat with a capture',       qr/^(.*)[yz]/s ],
        [ 'start class scan',            qr/(?:\d+q|[z]y)/ ],
        [ 'required substring search',   qr/a[bc]defgh/ ],
        [ 'lazy repeat looking ahead',   qr/^.*?[yz]q/s ],
        [ 'trying every position',       qr/(?:)\dq/ ],
    );
    for my $scan (@scans) {
        my ($name, $re) = @$scan;
        my ($small) = bounded(1000, $big, $re);
        like($small, $exhausted, "$name: a long subject exhausts a small budget");
        my ($large, $used) = bounded(50_000_000, $big, $re);
        is($large, 'no match', "$name: completes under a large budget");
        cmp_ok($used, '>=', length($big) / 8,
               "$name: charged in proportion to the subject");
    }

    # Looking for a later literal again from the start of every line
    my $lines = ("Received: from host\n" x 5000) . 'X-Spam: yes';
    watchdog(60);
    my ($result, $used) = bounded(1_000_000, $lines, qr/^Received:.*Spam/m);
    watchdog(0);
    like($result, $exhausted,
         'repeated searches of the rest of the string are charged each time');
}

# Memory taken while matching is charged too.
{
    # A negative lookahead saves the offsets of every open capture group
    # each time it is entered, so the same loop costs more with more of
    # them, although it visits the same number of nodes.
    my $subject = ('a' x 200) . 'b';
    my (undef, $few)  = bounded(10_000_000, $subject,
                                qr/^()(?:(?!b)a)+b\z/);
    my (undef, $many) = bounded(10_000_000, $subject,
                                qr/^${\ ('()' x 500)}(?:(?!b)a)+b\z/);
    cmp_ok($many, '>', 20 * $few, 'saved capture state is charged by size');
}

# A match that keeps captures across a budget failure.
{
    'first second' =~ /(\w+) (\w+)/ or die;
    eval { local ${^RE_BUDGET} = 2000; $slow_subject =~ $slow_re };
    is("$1 $2", 'first second',
       'captures of the last successful match survive an exhausted one');

    my $s = 'x ' . $slow_subject;
    $s =~ /\w+ /g or die;
    my $pos = pos $s;
    eval { local ${^RE_BUDGET} = 2000; $s =~ /\G(a+)+\1?$/g };
    like($@, $exhausted, 'scalar //g match exhausted');
    is(pos $s, $pos, 'pos is unchanged by an exhausted match');
}

# An exhausted match inside a code block of another match unwinds both.
{
    my $ok = eval {
        'xyz' =~ /x(?{ local ${^RE_BUDGET} = 2000; $slow_subject =~ $slow_re })y/;
        1;
    };
    ok(!$ok, 'exhaustion inside a code block propagates');
    like($@, $exhausted, '... with the budget message');
    ok('xyz' =~ /x(y)z/ && $1 eq 'y', 'the engine is usable afterwards');
    is(${^RE_BUDGET}, undef, '... and no budget is left in force');
}

# Compilation is charged against the same budget.
{
    my $words = join '|', map { "word$_" } 1 .. 5000;
    my $ok = eval { local ${^RE_BUDGET} = 1000; qr/$words/; 1 };
    ok(!$ok, 'a large pattern exhausts a small budget while compiling');
    like($@, qr/\ARegexp compilation budget exhausted in regex m\//,
         '... with the compilation message');
    my $re = eval { local ${^RE_BUDGET} = 5_000_000; qr/$words/ };
    ok(defined $re && 'a word4999 b' =~ $re, '... and compiles under a large one');

    my $groups = '(a)?' x 5000;
    $ok = eval { local ${^RE_BUDGET} = 100_000; qr/$groups/; 1 };
    ok(!$ok, 'many quantified groups exhaust a budget while compiling');
}

# ${^RE_RESTRICT} rejects what the budget cannot account for.
{
    sub IsMine { "0041\n" }
    my $with_code = qr/x(?{ 1 })/;

    my @allowed = (
        [ 'literals and classes',  'ab+c[a-z]\d\s\w.' ],
        [ 'anchors and boundaries', '^\Aa\b\B\z$' ],
        [ 'groups and captures',   '(a)(?:b)(?<n>c)(?|(d)|(e))' ],
        [ 'quantifiers',           'a*b+?c{2,3}d?+e*+' ],
        [ 'backreferences',        '(a)\1(?<n>b)\k<n>\g{-1}' ],
        [ 'lookaround',            '(?=a)(?!b)(?<=c)(?<!d)e' ],
        [ 'atomic group',          '(?>a+)b' ],
        [ 'conditional',           '(a)?(?(1)b|c)' ],
        [ 'backtracking verbs',    'a(*SKIP)b|c(*PRUNE)d|(*FAIL)' ],
        [ 'Unicode properties',    '\p{Lu}\p{IsAlpha}\p{Script=Greek}\P{L}' ],
        [ 'bracketed classes',     '[[:alpha:]][^\W\d](?[ [a-z] - [aeiou] ])' ],
        [ 'code point by number',  '\N{U+41}\x{100}\o{101}' ],
        [ 'case-insensitive',      '(?i)stra\x{df}e' ],
        [ 'generic newline',       '\R\h\v\N' ],
    );
    my @rejected = (
        [ 'code block',            'a(?{ 1 })',     qr/Eval-group not allowed in a restricted regexp/ ],
        [ 'postponed pattern',     'a(??{ "b" })',  qr/Eval-group not allowed in a restricted regexp/ ],
        [ 'whole-pattern recursion', 'a(?R)?b',     qr/Recursion not allowed in a restricted regexp/ ],
        [ 'numbered recursion',    '(a)(?1)',       qr/Recursion not allowed in a restricted regexp/ ],
        [ 'relative recursion',    '(a)(?-1)',      qr/Recursion not allowed in a restricted regexp/ ],
        [ 'named recursion',       '(?<n>a)(?&n)',  qr/Recursion not allowed in a restricted regexp/ ],
        [ 'grapheme cluster',      'a\X',           qr/\\X not allowed in a restricted regexp/ ],
        [ 'Unicode boundary',      '\b{wb}a',       qr/\\b\{\} not allowed in a restricted regexp/ ],
        [ 'script run',            '(*sr:\d+)',     qr/Script run not allowed in a restricted regexp/ ],
        [ 'atomic script run',     '(*asr:\d+)',    qr/Script run not allowed in a restricted regexp/ ],
        [ 'named character',       '\N{LATIN SMALL LETTER A}', qr/Named character not allowed in a restricted regexp/ ],
        [ 'user-defined property', '\p{IsMine}',    qr/Can't find Unicode property definition "IsMine"/ ],
        [ 'qualified user-defined property', '\p{main::IsMine}', qr/Illegal user-defined property name/ ],
        [ 'property not yet defined', '\p{IsNotThereYet}', qr/Can't find Unicode property definition/ ],
        [ 'property wildcard',     '\p{nv=/\A[0-5]\z/}', qr/Unicode property wildcard not allowed in a restricted regexp/ ],
        [ 'Name property',         '\p{name=DIGIT ONE}', qr/The Name property is not allowed in a restricted regexp/ ],
    );

    for my $test (@allowed) {
        my ($name, $pattern) = @$test;
        my $re = eval { local ${^RE_RESTRICT} = 1; qr/$pattern/ };
        ok(defined $re, "restricted: $name compiles") or diag($@);
    }
    for my $test (@rejected) {
        my ($name, $pattern, $message) = @$test;
        my $re = eval { local ${^RE_RESTRICT} = 1; qr/$pattern/ };
        ok(!defined $re, "restricted: $name is rejected");
        like($@, $message, "restricted: $name gives its message");
    }

    my $re = eval { local ${^RE_RESTRICT} = 1; qr/a$with_code/ };
    ok(!defined $re, 'restricted: a code block in an interpolated qr// is rejected');
    like($@, qr/Eval-group not allowed in a restricted regexp/,
         '... with the code block message');

    # An attempt to close a wrapper and carry on is just more pattern.
    my $escape = 'a)(?{ die "escaped" })(b';
    $re = eval { local ${^RE_RESTRICT} = 1; qr/(?:$escape)/ };
    ok(!defined $re, 'restricted: text that closes a group early is still restricted');

    # The usual way to use the two together.
    my $untrusted = '^(a+)+\1?$';
    my $result = eval {
        local ${^RE_RESTRICT} = 1;
        local ${^RE_BUDGET} = 100_000;
        (('a' x 40) . 'b') =~ /$untrusted/ ? 'match' : 'no match';
    };
    like($@, $exhausted, 'restricted and budgeted untrusted pattern is stopped');
}

SKIP: {
    skip('no ithreads', 3) unless $Config{useithreads};
    require threads;
    local ${^RE_BUDGET} = 5000;
    my ($child_start, $child_end) = @{ threads->create(sub {
        my $start = ${^RE_BUDGET};
        'abc' =~ /b/;
        return [ $start, ${^RE_BUDGET} ];
    })->join };
    is($child_start, 5000, 'a new thread starts with a copy of the budget');
    cmp_ok($child_end, '<', 5000, '... and spends its own copy');
    is(${^RE_BUDGET}, 5000, '... leaving the parent budget alone');
}

done_testing();
