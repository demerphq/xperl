#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use async;
use feature qw(state lexical_subs);
no warnings 'experimental::builtin';

my async sub answer ($value) {
    await XPerl::Task->delay(0);
    return $value + 1;
}
my $task = answer(41);
isa_ok($task, 'XPerl::Task');
is(run($task), 42, 'lexical async sub returns a task');
ok(!defined(&main::answer), 'lexical async name is not installed in the package');

sub make_adder ($offset) {
    my async sub add ($value) {
        await XPerl::Task->delay(0);
        return $offset + $value;
    }
    return \&add;
}
my ($a, $b) = (make_adder(10), make_adder(20));
is(run($a->(2)), 12, 'first lexical factory retains its outer capture');
is(run($b->(2)), 22, 'second lexical factory has a separate capture');

my @code;
for my $value (1 .. 5) {
    my async sub saved () {
        await XPerl::Task->delay(0);
        return $value;
    }
    push @code, \&saved;
}
is(join(',', map { run($_->()) } @code), '1,2,3,4,5',
   'reentering a scope preserves escaped lexical factories');

for (1 .. 20) {
    my async sub temporary () { return 42 }
    die 'wrong result' unless run(temporary()) == 42;
}
pass('an unescaped lexical pad slot can be reused');

{
    my sub recurse;
    async sub recurse ($depth) {
        return $depth ? $depth + await recurse($depth - 1) : 0;
    }
    is(run(recurse(8)), 36, 'forward lexical declaration supports named async recursion');
    undef &recurse;
}

sub shared_counter () {
    state async sub count () {
        state $value = 0;
        await XPerl::Task->delay(0);
        return ++$value;
    }
    return \&count;
}
my $counter = shared_counter();
is(run($counter->()), 1, 'state in the body initializes normally');
is(run(shared_counter()->()), 2, 'state lexical function retains its body between calls');

sub make_counter ($start) {
    return sub {
        state async sub count () {
            state $value = $start;
            await XPerl::Task->delay(0);
            return ++$value;
        }
        return \&count;
    };
}
my ($left, $right) = (make_counter(10)->(), make_counter(20)->());
is(run($left->()), 11, 'state async body captures the first enclosing closure');
is(run($right->()), 21, 'state async body captures the second enclosing closure');
is(run($left->()), 12, 'state remains local to that lexical function instance');

{
    no feature 'signatures';
    my async sub single ($) { return $_[0] + 1 }
    is(prototype(\&single), '$', 'traditional lexical async prototype is retained');
    is(run(single(41)), 42, 'traditional lexical async body receives arguments');
}

{
    my $source = "use utf8; no feature q(signatures); no warnings q(illegalproto); "
        . "my async sub f(" . pack('C*', 195, 169) . "){42} prototype(\\&f)";
    my $proto = eval $source;
    ok(utf8::is_utf8($proto), 'prototype preserves its UTF-8 flag');
    is(ord($proto), 233, 'prototype preserves its Unicode character');
}

fresh_perl_is(<<'PERL', 'ok', {}, 'async remains usable as a package type name');
use xperl;
package async {};
my async $value;
print 'ok';
PERL

fresh_perl_is(<<'PERL', '42', {}, 'nested state async declarations find the cloned enclosing body');
use xperl;
my $task = sub {
    state sub a;
    state async sub b {
        state async sub c {
            state $value = 42;
            async sub a { $value }
        }
        await c();
    }
    run(b());
    return a();
}->();
print run($task);
PERL

fresh_perl_is(<<'PERL', '42', {}, 'a lexical task may outlive its creating string eval');
use xperl;
my $task = eval q{
    my $value = 42;
    my async sub saved () {
        my $capture = $value;
        await XPerl::Task->delay(0);
        return eval '$value';
    }
    saved();
};
die $@ if $@;
print run($task);
PERL

fresh_perl_is(<<'PERL', '42', {}, 'an escaped body survives undefining its factory and parent');
use xperl;
use B ();
sub creator {
    state $value = 42;
    state async sub saved () {
        my $capture = $value;
        return eval '$value';
    }
    my $body = B::svref_2object(\&saved)->ASYNC_BODY->object_2svref;
    undef &saved;
    return $body;
}
my $parent = \&creator;
my $body = $parent->();
undef &$parent;
undef $parent;
print $body->();
PERL

fresh_perl_is(<<'PERL', '42', {}, 'a task survives undefining its lexical factory and parent');
use xperl;
sub creator {
    state $value = 42;
    state async sub saved () {
        my $capture = $value;
        await XPerl::Task->delay(0);
        return eval '$value';
    }
    my $task = saved();
    undef &saved;
    return $task;
}
my $parent = \&creator;
my $task = $parent->();
undef &$parent;
undef $parent;
print run($task);
PERL

SKIP: {
    skip 'requires XS::APItest', 1 unless eval { require XS::APItest; 1 };
    my $source = q{async sub rejected :lvalue () { my $value = 42; $value }};
    my $reject = sub {
        my sub rejected;
        eval $source;
        $@ = '';
        ${^ERROR_OBJ} = undef;
    };
    $reject->() for 1 .. 10;
    my $before = XS::APItest::sv_count();
    $reject->() for 1 .. 100;
    is(XS::APItest::sv_count(), $before,
       'rejected runtime definitions release their temporary lexical factory');
}

for my $declarator (qw(my state)) {
    my $source = "use async; use feature qw(state lexical_subs); "
        . "$declarator sub invalid :lvalue; async sub invalid () { our \$v; \$v }";
    eval $source;
    ok($@, "async definition rejects inherited $declarator lvalue attribute");
    is(${^ERROR_OBJ}->diagnostics->[0]->code, 'ERROR_ASYNC_DECLARATION_UNSUPPORTED',
       'rejection uses the async declaration diagnostic');
}

fresh_perl_is(<<'PERL', '42', {}, 'a rejected runtime redefinition preserves the existing lexical sub');
use xperl;
no warnings 'redefine';
my sub saved () { 42 }
my $value = 21;
eval q{async sub saved :lvalue () { $value }};
die 'declaration was accepted' unless $@;
print saved();
PERL

for my $declarator (qw(my state)) {
    my $body = $declarator eq 'my' ? '$value' : '42';
    my $program = <<'PERL';
use xperl;
use attributes ();
no warnings 'redefine';
sub MODIFY_CODE_ATTRIBUTES {
    my ($package, $code) = @_;
    attributes::_modify_attrs($code, 'lvalue');
    return;
}
sub exercise {
    my $value = 21;
    DECLARATOR sub saved () { 42 }
    my $hold = \&saved;
    eval q{async sub saved :ForceLvalue () { BODY }};
    die 'declaration was accepted' unless $@;
    die 'replaced the original function' unless \&saved == $hold;
    print saved();
}
exercise();
PERL
    $program =~ s/DECLARATOR/$declarator/;
    $program =~ s/BODY/$body/;
    fresh_perl_is($program, '42', {},
                  "a rejected attribute hook preserves the existing $declarator sub");

    $program = <<'PERL';
use xperl;
no warnings 'redefine';
sub exercise {
    my $value = 42;
    DECLARATOR sub saved () { 0 }
    eval q{async sub saved () { BODY }};
    die $@ if $@;
    print run(saved());
}
exercise();
PERL
    $program =~ s/DECLARATOR/$declarator/;
    $program =~ s/BODY/$body/;
    fresh_perl_is($program, '42', {},
                  "a successful runtime definition replaces the existing $declarator sub");
}

my $sourcefile = tempfile();
open my $source, '>', $sourcefile or die "open $sourcefile: $!";
print {$source} <<'PERL';
use async;
use feature qw(state lexical_subs);
no warnings 'experimental::builtin';
my async sub add ($value) { return $value + 20 }
state async sub constant () { return 42 }
print run(add(22)), ',', run(constant());
PERL
close $source or die "close $sourcefile: $!";
my $deparsed = runperl(switches => ['-MO=Deparse'], progfile => $sourcefile, stderr => 1);
$deparsed =~ s/^\Q$sourcefile\E syntax OK\n//m;
like($deparsed, qr/my async sub add/, 'deparser preserves a my async declaration');
like($deparsed, qr/state async sub constant/, 'deparser preserves a state async declaration');
fresh_perl_is($deparsed, '42,42', {}, 'deparsed lexical async functions compile and run');

done_testing();
