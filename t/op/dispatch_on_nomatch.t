#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;

for my $mode (qw(none array-linear array-binary hv auto)) {
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    my $program = <<'PROG';
use feature 'dispatch_on';
my @code = (
    'dispatch (3) { on (1) { 1 } on (2) { 2 } };',
    'my $value = do { dispatch (3) { on (1) { 1 } on (2) { 2 } } };',
    'my @values = do { dispatch (3) { on (1) { 1 } on (2) { 2 } } };',
    'dispatch (3) {};',
    'dispatch (3) { on (_ if 0) { 1 } };',
);
for (@code) {
    eval $_;
    my $error = $@;
    die 'expected exception' unless ref $error;
    print $error->contents->[0]->code, "\n";
}
PROG
    fresh_perl_is($program, "ERROR_CONTROL_FLOW_DISPATCH_NO_MATCH\n" x 5, {},
                  "$mode: unmatched dispatch throws in every context");

    $program = <<'PROG';
use feature 'dispatch_on';
my $value = do { dispatch (3) { on (1) { 1 } on (_) { 'fallback' } } };
my $expected = bless {}, 'CustomError';
eval { dispatch (3) { on (1) { 1 } on (_) { die $expected } } };
my $actual = $@;
die 'exception identity changed' unless $actual == $expected;
my @empty = do { dispatch (3) { on (1) { 1 } on (_) {} } };
print "$value:", ref($actual), ':', @empty ? 'wrong' : 'empty';
PROG
    fresh_perl_is($program, 'fallback:CustomError:empty', {},
                  "$mode: explicit defaults retain their result or exception");

    $program = <<'PROG';
use feature 'dispatch_on';
eval {
#line 23 "dispatch-site.pl"
    dispatch (3) {
#line 67 "first-clause.pl"
        on (1) { 1 }
#line 89 "last-clause.pl"
        on (2) { 2 }
    }
};
my $diagnostic = $@->contents->[0];
die 'wrong exception class' unless $diagnostic->isa(
    'XPerl::Diagnostic::Error::Dispatch::NoMatch');
print join ':', @{$diagnostic->location}{qw(file line)};
PROG
    fresh_perl_is($program, 'dispatch-site.pl:23', {},
                  "$mode: no-match reports the dispatch statement");
}

my $redo_program = <<'PROG';
use feature 'dispatch_on';
my $tries = 0;
eval {
    dispatch (1) {
        on (1 if ++$tries == 1) { redo }
    }
};
my $error = $@;
print "$tries:", $error->contents->[0]->code;
PROG
fresh_perl_is($redo_program, '2:ERROR_CONTROL_FLOW_DISPATCH_NO_MATCH', {},
              'redo tries the clauses again and throws if none now match');

my $deparse_program = <<'PROG';
use feature 'dispatch_on';
use B::Deparse;
my $original = sub { dispatch ($_[0]) { on (1) { 'one' } } };
my $text = B::Deparse->new->coderef2text($original);
my $copy = eval "sub $text";
die $@ unless $copy;
die 'matched result changed' unless $copy->(1) eq 'one';
eval { $copy->(2) };
my $error = $@;
print $error->contents->[0]->code;
PROG
fresh_perl_is($deparse_program, 'ERROR_CONTROL_FLOW_DISPATCH_NO_MATCH', {},
              'deparsed dispatch retains no-match behavior');

my $multi_program = <<'PROG';
use feature 'multisub';
no warnings 'experimental::multisub';
multi sub example(1) { 'one' }
eval { example(2) };
my $diagnostic = $@->contents->[0];
die 'wrong exception class' unless $diagnostic->isa(
    'XPerl::Diagnostic::Error::Dispatch::NoMatch');
print $diagnostic->code;
PROG
fresh_perl_is($multi_program, 'ERROR_RUNTIME_MULTISUB_NO_MATCH', {},
              'multi shares the no-match class and retains its own code');

done_testing();
