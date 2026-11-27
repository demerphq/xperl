#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
}

use strict;
use warnings;

my $program = <<'PROG';
use xperl;

multi sub fib(0) { 0 }
multi sub fib(1) { 1 }
multi sub fib($n if $n > 1) { fib($n - 1) + fib($n - 2) }
say fib(10);

dispatch ([3, 'value']) {
    on ([Int(), $value]) { say $value }
}

my $g = gen { yield 7 };
say $g->();
$g->();
say $g->completed ? 'completed' : 'wrong';

class Example {
    multi method value(0) { 0 }
    multi method value($n if $n > 0) { $n }
}
my $object = Example->new;
say $object->value(4);
say is_class_object($object) ? 'class' : 'wrong';

sub named(:$value) { $value }
say named(value => 9);
say is_bool(true) && !false ? 'builtins' : 'wrong';
async sub increment($value) { return $value + 1 }
say run(increment(4));
PROG
fresh_perl_is($program, "55\nvalue\n7\ncompleted\n4\nclass\n9\nbuiltins\n5\n", {},
              'one pragma enables XPerl syntax and supporting functions');

$program = <<'PROG';
use xperl;
sub work () {
    defer { say 'outer cleanup' }
    {
        defer { say 'inner cleanup' }
        say 'body';
    }
    say 'after inner';
}
work();
PROG
fresh_perl_is($program, "body\ninner cleanup\nafter inner\nouter cleanup\n", {},
              'xperl enables defer with cleanup at each scope exit');

$program = <<'PROG';
use feature ();
my (@before, @after);
BEGIN { @before = sort(feature::features_enabled(0)) }
{
    use xperl;
    BEGIN {
        my %old = map { $_ => 1 } qw(
            apostrophe_as_package_separator bareword_filehandles
            indirect multidimensional smartmatch switch
        );
        my $want = join ' ', sort grep { !$old{$_} } keys %feature::feature;
        my $got = join ' ', sort(feature::features_enabled(0));
        die "feature mismatch: $got" unless $got eq $want;
    }
    die 'builtin leaked into package' if main->can('is_bool');
    die 'predicate leaked into package' if main->can('Int');
}
BEGIN { @after = sort(feature::features_enabled(0)) }
die 'features leaked out of scope' unless "@before" eq "@after";
eval { is_bool(1) };
die 'builtin leaked out of scope' unless $@;
eval { Int(1) };
die 'predicate leaked out of scope' unless $@;
print 'lexical';
PROG
fresh_perl_is($program, 'lexical', {},
              'features and imported functions stay in their lexical scope');

$program = <<'PROG';
use xperl;
use xperl;
use builtin ':all';
{
    use xperl;
    dispatch (3) { on (Int()) { print trim(' inner ') } }
}
dispatch (4) { on (Integer()) { print ':outer' } }
{
    my sub Int($value) { 'custom' }
    use xperl;
    print ':', Int(3);
}
PROG
fresh_perl_is($program, 'inner:outer:custom', {},
              'repeated imports retain aliases and explicit predicate overrides');

$program = <<'PROG';
use xperl;
my $error = eval '$undeclared = 1; 1' ? '' : $@;
die 'strict vars not enabled' unless $error =~ /requires explicit package name/;
my $warning = '';
{
    local $SIG{__WARN__} = sub { $warning .= shift };
    my $undefined;
    my $text = "$undefined";
}
die 'ordinary warnings disabled' unless $warning =~ /uninitialized/;
print 'strict and warnings';
PROG
fresh_perl_is($program, 'strict and warnings', {},
              'strictness and ordinary warnings are enabled');

$program = <<'PROG';
{
    use xperl;
    no feature 'multisub';
    local $SIG{__WARN__} = sub { };
    eval 'multi sub disabled(0) { 0 }';
    die 'feature override ignored' unless $@;
}
eval '$outside = 1; 1' or die 'strictness leaked out of scope';
print 'overrides';
PROG
fresh_perl_is($program, 'overrides', {},
              'features can be overridden and strictness does not leak');

$program = <<'PROG';
use xperl;
sub namespace($value) { $value }
sub as($value) { $value }
sub __NAMESPACE__() { 'ordinary functions' }
say namespace(as(__NAMESPACE__()));
BEGIN {
    package ImportArguments;
    sub import { shift; $main::arguments = join ',', @_ }
    $INC{'ImportArguments.pm'} = __FILE__;
}
use ImportArguments as => 'Short';
say $main::arguments;
eval q{use feature 'namespaces'};
die 'removed feature accepted' unless $@;
PROG
fresh_perl_is($program, "ordinary functions\nas,Short\n", {},
              'namespace and as are ordinary names and import arguments');

done_testing();
