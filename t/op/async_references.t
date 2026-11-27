#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
    skip_all_without_dynamic_extension('B');
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use async;
use feature qw(state class);
no warnings qw(experimental::class experimental::builtin);

our ($early, $alias);
BEGIN {
    $early = \&answer;
    *early_alias = \&answer;
}
async sub answer() { return 42 }
is($early, \&answer, 'a reference taken before the definition keeps the public identity');
is(\&early_alias, \&answer, 'a code alias to the reservation keeps that identity');
my $task = $early->();
isa_ok($task, 'XPerl::Task');
is(run($task), 42, 'an early reference creates and runs a task');
is(run(early_alias()), 42, 'the early alias creates a task');

our $forward;
sub declared;
BEGIN { $forward = \&declared }
async sub declared() { return 43 }
is($forward, \&declared, 'an explicit forward declaration is completed in place');
is(run($forward->()), 43, 'a forward-declared reference calls the factory');

our $state_ref;
BEGIN { $state_ref = \&stateful }
my $outside = 7;
async sub stateful() {
    state $count = 0;
    return [++$count, \$count, \$outside, sub { $count += 10 }];
}
my $first = run($state_ref->());
my $second = run(stateful());
is($first->[0], 1, 'state initializes in the retained body');
is($second->[0], 2, 'early and normal calls share state');
is($first->[1], $second->[1], 'the state variable keeps its storage identity');
is($first->[2], \$outside, 'captured lexical storage is shared with its owner');
$first->[3]->();
is(run($state_ref->())->[0], 13, 'an escaped nested closure shares that state');

our $method_ref;
class ForwardMethod {
    field $value :param;
    method read;
    BEGIN { $method_ref = \&ForwardMethod::read }
    async method read() {
        await XPerl::Task->delay(0);
        return $value;
    }
}
my $object = ForwardMethod->new(value => 44);
is($method_ref, ForwardMethod->can('read'), 'an early method reference keeps its identity');
is(run($object->$method_ref), 44, 'the completed method retains its field map');

{
    no warnings 'redefine';
    my $old = \&answer;
    eval q{async sub answer() { 99 }};
    is($@, '', 'a real redefinition compiles');
    isnt(\&answer, $old, 'a real redefinition creates a separate callable');
    is(run($old->()), 42, 'existing references keep the old definition');
    is(run(answer()), 99, 'the name calls the new factory');
}

fresh_perl_is(<<'PERL', 'same:same:XPerl::Task:42', {}, 'attribute callbacks see the published factory');
use xperl;
our ($argument, $lookup, $task);
sub MODIFY_CODE_ATTRIBUTES {
    my ($package, $code) = @_;
    $argument = $code;
    $lookup = \&answer;
    $task = $code->();
    return;
}
async sub answer :Capture () { 42 }
print join ':', $argument == \&answer ? 'same' : 'different',
    $lookup == \&answer ? 'same' : 'different', ref($task), run($task);
PERL

fresh_perl_is(<<'PERL', '7:9', {}, 'an escaped replacement factory survives rejection of its binding');
use xperl;
no warnings 'redefine';
our $captured;
sub answer() { 7 }
sub MODIFY_CODE_ATTRIBUTES { $captured = $_[1]; die "rejected\n" }
eval q{async sub answer :Reject () { 9 }};
die 'declaration was accepted' unless $@;
print answer(), ':', run($captured->());
PERL

fresh_perl_is(<<'PERL', '7:42', {}, 'an inherited cache entry is not reused as a local reservation');
use xperl;
our $inherited;
class CachedParent { method value() { 7 } }
class CachedChild :isa(CachedParent) {
    BEGIN { $inherited = CachedChild->can('value') }
    async method value() { 42 }
}
my $object = CachedChild->new;
print $object->$inherited(), ':', run($object->value());
PERL

fresh_perl_is(<<'PERL', '42:7', {}, 'a rejected redefinition preserves the old function and pending tasks');
use xperl;
no warnings 'redefine';
sub MODIFY_CODE_ATTRIBUTES { die "rejected\n" }
async sub old() { 42 }
my $pending = old();
sub answer() { 7 }
eval q{async sub answer :Reject () { 9 }};
die 'definition accepted' unless $@;
print run($pending), ':', answer();
PERL

fresh_perl_is(<<'PERL', 'same:undefined:method:same:same', {}, 'rejection restores the actual forward stub state');
use xperl;
use B ();
sub MODIFY_CODE_ATTRIBUTES { die "rejected\n" }
sub pending :method;
my $before = \&pending;
my $pad = ${B::svref_2object($before)->PADLIST};
my $outside = ${B::svref_2object($before)->OUTSIDE};
eval q{async sub pending :Reject () { 42 }};
die 'definition accepted' unless $@;
print join ':', $before == \&pending ? 'same' : 'different',
    defined(&pending) ? 'defined' : 'undefined',
    join(',', attributes::get(\&pending)),
    ${B::svref_2object($before)->PADLIST} == $pad ? 'same' : 'different',
    ${B::svref_2object($before)->OUTSIDE} == $outside ? 'same' : 'different';
PERL

fresh_perl_is(<<'PERL', 'undefined:42', {}, 'defining a code alias does not fill the original name');
use xperl;
no warnings 'redefine';
BEGIN { *alias = \&original }
async sub alias() { 42 }
print defined(&original) ? 'defined:' : 'undefined:', run(alias());
PERL

fresh_perl_is(<<'PERL', '42', {}, 'a nested named async body follows a moved enclosing pad');
use xperl;
no warnings 'closure';
our $builder;
BEGIN { $builder = \&build }
sub build {
    my $value = 42;
    async sub nested() {
        await XPerl::Task->delay(0);
        return $value;
    }
    return \&nested;
}
print run($builder->()->());
PERL

fresh_perl_is(<<'PERL', 'rejected:undefined:7', {}, 'a callback cannot silently undefine the provisional factory');
use xperl;
no warnings 'redefine';
our $old;
sub answer() { 7 }
sub MODIFY_CODE_ATTRIBUTES { undef &answer; return }
$old = \&answer;
eval q{async sub answer :Remove () { 9 }};
print $@ ? 'rejected:' : 'accepted:', defined(&answer) ? 'defined:' : 'undefined:', $old->();
PERL

fresh_perl_is(<<'PERL', 'nested rejection:10', {}, 'outer rollback preserves a nested declaration using the same CV');
use xperl;
no warnings 'redefine';
sub pending :method;
sub MODIFY_CODE_ATTRIBUTES {
    undef &pending;
    eval q{async sub pending() { 10 }};
    die $@ if $@;
    die "nested rejection\n";
}
eval q{async sub pending :Replace () { 9 }};
my ($message) = split /\n/, $@;
print $message, ':', run(pending());
PERL

fresh_perl_is(<<'PERL', 'released', {}, 'a redefined factory has no ownership cycle through its glob');
use xperl;
no warnings 'redefine';
eval q{package TemporaryAsync; async sub value() { 7 }};
my $code = eval q{package TemporaryAsync; async sub value() { 42 }; \&value};
die $@ if $@;
weaken($code);
delete $TemporaryAsync::{value};
print defined($code) ? 'retained' : 'released';
PERL

for my $replacement ('*answer = *replacement', '*answer = sub { 88 }') {
    my $program = <<'PERL';
use xperl;
no warnings 'redefine';
our ($old, $captured);
sub answer() { 7 }
sub replacement() { 88 }
sub MODIFY_CODE_ATTRIBUTES {
    $captured = $_[1];
    REPLACE;
    return;
}
$old = \&answer;
eval q{async sub answer :ReplaceName () { 9 }};
die 'replacement was not detected' unless $@;
print answer(), ':', $old->(), ':', run($captured->());
PERL
    $program =~ s/REPLACE/$replacement/;
    fresh_perl_is($program, '88:7:9', {},
                  'callback rebinding preserves the replacement and escaped factory');
}

fresh_perl_is(<<'PERL', 'same:XPerl::Task:42', {}, 'debugger callbacks see the completed factory');
use xperl;
our ($saved, $task);
sub DB::postponed {
    $saved = \&answer;
    $task = $saved->();
}
BEGIN {
    $^P |= 0x10;
    $DB::postponed{'main::answer'} = 1;
}
async sub answer() { 42 }
print join ':', $saved == \&answer ? 'same' : 'different', ref($task), run($task);
PERL

SKIP: {
    skip 'requires XS::APItest', 2 unless eval { require XS::APItest; 1 };
    fresh_perl_is(<<'PERL', '1,2', {}, 'a forward stub keeps its call checker when completed');
use xperl;
no feature 'signatures';
use XS::APItest ();
sub checked($);
BEGIN { XS::APItest::cv_set_call_checker_lists(\&checked) }
async sub checked($) { join ',', @_ }
my @values = (1, 2);
print run(checked(@values));
PERL

    fresh_perl_is(<<'PERL', '10', {}, 'code magic transforms the retained compiler body');
use xperl;
use XS::APItest;
async sub transformed() {
    BEGIN { sv_magicv2_add(&{PL_compcv()}, 'add_one_to_expr', undef) }
    9;
}
print run(transformed());
PERL
}

SKIP: {
    skip 'requires Sub::Util', 2 unless eval { require Sub::Util; 1 };
    fresh_perl_is(<<'PERL', 'bytes:42', {}, 'completing a forward stub copies the new prototype encoding');
use xperl;
use Sub::Util ();
no feature 'signatures';
sub checked($);
BEGIN {
    my $prototype = '$';
    utf8::upgrade($prototype);
    Sub::Util::set_prototype($prototype, \&checked);
}
async sub checked($) { 42 }
print utf8::is_utf8(prototype(\&checked)) ? 'utf8:' : 'bytes:', run(checked(0));
PERL

    fresh_perl_is(<<'PERL', 'utf8:undefined', {}, 'rejected completion restores the original prototype encoding');
use xperl;
use Sub::Util ();
no feature 'signatures';
sub checked($);
BEGIN {
    my $prototype = '$';
    utf8::upgrade($prototype);
    Sub::Util::set_prototype($prototype, \&checked);
}
sub MODIFY_CODE_ATTRIBUTES { die "rejected\n" }
eval q{async sub checked($) :Reject { 42 }};
die 'declaration was accepted' unless $@;
print utf8::is_utf8(prototype(\&checked)) ? 'utf8:' : 'bytes:',
    defined(&checked) ? 'defined' : 'undefined';
PERL
}

fresh_perl_is(<<'PERL', 'removed', {}, 'scope cleanup can delete the new name before compilation returns');
use xperl;
no warnings 'redefine';
our $removed;
sub DefinitionGuard::DESTROY {
    delete $main::{answer};
    $removed = 1;
}
BEGIN {
    my $guard = bless {}, 'DefinitionGuard';
    *answer = sub { $guard };
}
async sub answer() { 42 }
print $removed && !defined(&answer) ? 'removed' : 'not removed';
PERL

SKIP: {
    skip 'requires ithreads', 2 unless $Config::Config{useithreads};
    skip 'requires threads extension', 2 unless eval { require threads; 1 };
    fresh_perl_is(<<'PERL', '42:42', {}, 'a child interpreter can clone a provisionally published factory');
use xperl;
use threads ();
our ($early, $child_result);
BEGIN { $early = \&answer }
sub MODIFY_CODE_ATTRIBUTES {
    my ($package, $code) = @_;
    my $thread = threads->create(sub { run($early->()) });
    $child_result = $thread->join;
    return;
}
async sub answer :CloneDuringDeclaration () { 42 }
print $child_result, ':', run(answer());
PERL

    fresh_perl_is(<<'PERL', '42:42', {}, 'a destructor can clone the committed factory during declaration cleanup');
use xperl;
use threads ();
no warnings qw(redefine prototype);
our $child_result;
sub DefinitionGuard::DESTROY {
    return if threads->tid;
    my $thread = threads->create(sub { run(main->can('answer')->()) });
    $child_result = $thread->join;
}
use constant answer => bless {}, 'DefinitionGuard';
async sub answer() { 42 }
print $child_result, ':', run(main->can('answer')->());
PERL
}

done_testing();
