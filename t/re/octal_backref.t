#!./perl

# A bare \NN after fewer than NN capture groups is an octal escape, and
# otherwise a backreference.  Inside a branch reset, several groups in the
# pattern share one number, so there are more groups than numbers.  These
# tests check that the pattern compiler uses the numbers, and uses them
# consistently: it used to loop forever, allocating memory, when the two
# counts fell either side of NN.

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require './charset_tools.pl';
}

use strict;
use warnings;

my $bs = "\010";    # what \10 means as an octal escape; a control
                    # character on every platform

sub compiled {
    my $pattern = shift;
    watchdog(60);
    my $re = eval { qr/$pattern/ };
    watchdog(0);
    return $re;
}

# [ pattern, subject, expected to match, description ]
my @tests = (
    [ '(?|(a)(b)(c)(d)(e)(f)|(g)(h)(i)(j))\10', "abcdef$bs", 1,
      'six numbers, ten groups: \10 is octal' ],
    [ '(?|(a)(b)(c)(d)(e)(f)|(g)(h)(i)(j))\10', "ghij$bs", 1,
      'six numbers, ten groups: \10 is octal after the shorter branch' ],
    [ '(?|(a)(b)(c)(d)(e)(f)|(g)(h)(i)(j))\10', "abcdefa", 0,
      'six numbers, ten groups: \10 is not a backreference' ],
    [ '(?|()()()()()()()()()|())\10', $bs, 1,
      'nine numbers, ten groups: \10 is octal' ],
    [ '(?|()|())()()()()()()()()\10', $bs, 1,
      'nine numbers, ten groups, branch reset first: \10 is octal' ],
    [ '(?|(a)|(b))(c)(d)(e)(f)(g)(h)(i)(j)(k)\10', "acdefghijkk", 1,
      'ten numbers, eleven groups: \10 is a backreference' ],
    [ '(?|(a)|(b))(c)(d)(e)(f)(g)(h)(i)(j)(k)\10', "acdefghijk$bs", 0,
      'ten numbers, eleven groups: \10 is not octal' ],
    [ '(?|(a)(b)|(c))(d)(e)(f)(g)(h)(i)(j)(k)\11', "abdefghijk\011", 1,
      'ten numbers, eleven groups: \11 is octal' ],
    [ '(?|(a)(b)|(c))(d)(e)(f)(g)(h)(i)(j)(k)x\10', "abdefghijkxk", 1,
      'ten numbers, eleven groups: \10 after a literal is a backreference' ],
    [ '(a)(b)(c)(d)(e)(f)(g)(h)(i)x\10', "abcdefghix$bs", 1,
      'nine groups, no branch reset: \10 after a literal is octal' ],
    [ '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)x\10', "abcdefghijxj", 1,
      'ten groups, no branch reset: \10 after a literal is a backreference' ],
    [ '(?|(a)(b)(c)(d)(e)(f)|(g)(h)(i)(j))x\10y', "abcdefx${bs}y", 1,
      'six numbers, ten groups: \10 inside a literal is octal' ],
    [ '(?|(a)(b)|(c)(d))\2', "abb", 1,
      'branch reset: \2 is a backreference to the shared number' ],
);

for my $test (@tests) {
    my ($pattern, $subject, $want, $name) = @$test;
    my $re = compiled($pattern);
    ok(defined $re, "$name: compiles") or diag($@);
    SKIP: {
        skip('pattern did not compile', 1) unless defined $re;
        my $got = $subject =~ /\A$re\z/ ? 1 : 0;
        is($got, $want, "$name: " . ($want ? 'matches' : 'does not match'));
    }
}

done_testing();
