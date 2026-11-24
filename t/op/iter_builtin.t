#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use generator;
use builtin qw(iter indexed);
no warnings 'experimental::builtin';

sub is_deeply {
    my ($got, $expected, $name) = @_;
    ok(eq_array($got, $expected), $name);
}

my $calls = 0;
my $stream = iter(sub { ++$calls }, 5);
is($calls, 0, 'constructing iter does not call the producer');
{
    local $@ = 'earlier error';
    my $unused = iter(sub { 1 }, 2);
    is($@, 'earlier error', 'constructing an adapter preserves the current exception');
}
my @seen;
for ($stream) {
    is($calls, $_, 'for pulls one item before entering the body');
    push @seen, $_;
    last if $_ == 2;
}
is_deeply(\@seen, [1, 2], 'last stops an unbounded producer immediately');
is($calls, 2, 'last does not request another item');
@seen = ();
push @seen, $_ for $stream;
is_deeply(\@seen, [3, 4], 'a later loop resumes the same adapter');
is($calls, 5, 'the stop value is consumed but not returned');
is_deeply([map { $_ } $stream], [], 'completed adapter stays empty');

my $batch = iter(gen { yield (); yield undef; yield (0, ''); return (7, 8) });
@seen = ();
for ($batch) { push @seen, $_; last }
is_deeply(\@seen, [undef], 'empty yields are skipped and undef is a value');
is_deeply([map { $_ } $batch], [0, '', 7, 8],
          'pending yield and final return values survive an early last');

my $direct = iter(gen { yield undef; yield 42 });
ok(!defined $direct->(), 'direct scalar call returns yielded undef');
ok(!$direct->completed, 'yielded undef does not mean completion');
is($direct->(), 42, 'direct scalar call returns the value, not its count');
is_deeply([$direct->()], [], 'direct list call reports completion');

is_deeply([map { $_ } iter(gen { return (1, 2, 3) }, 'never')], [1, 2, 3],
          'native completion applies even when a stop value is supplied');
is_deeply([map { $_ } iter(gen { return (1, 2, 3) }, 2)], [1],
          'a native batch stops at a matching value');

my @items = (undef, '', 0, '0', 'stop');
is_deeply([map { $_ } iter(sub { shift @items }, 'stop')], [undef, '', 0, '0'],
          'false values are data when they differ from the stop value');
@items = ('', 0, undef, 99);
is_deeply([map { $_ } iter(sub { shift @items }, undef)], ['', 0],
          'explicit undef stop matches only undef');
eval { iter(sub { 1 }) };
like("$@", qr/requires a stop value/, 'plain callable requires an explicit stop');

{
    package IterCallable;
    use overload '&{}' => sub { sub { die "wrong call path\n" } }, fallback => 1;
    sub can { return }
    sub CALL { ++$_[0]{calls} }
}
my $object = bless { calls => 0 }, 'IterCallable';
is_deeply([map { $_ } iter($object, 3)], [1, 2], 'CALL takes precedence over call overload');
{
    package IterOverload;
    use overload '&{}' => sub { my $self = shift; sub { ++$self->{calls} } }, fallback => 1;
}
$object = bless { calls => 0 }, 'IterOverload';
is_deeply([map { $_ } iter($object, 3)], [1, 2], 'call overload works without CALL');

my ($recursive, $recursive_calls);
$recursive = iter(sub {
    if (!$recursive_calls++) {
        my @end = $recursive->();
        return 42;
    }
    return 0;
}, 0);
is_deeply([$recursive->()], [], 'completion during a recursive pull remains final');

$calls = 0;
my $redo = 0;
@seen = ();
for (iter(sub { ++$calls }, 4)) {
    if ($_ == 1 && !$redo++) { redo }
    next if $_ == 2;
    push @seen, $_;
}
is_deeply(\@seen, [1, 3], 'redo repeats the current item and next advances');
is($calls, 4, 'redo does not pull from the producer');

my $replace = iter(gen { yield 1; yield 2 });
@seen = ();
for ($replace) {
    push @seen, $_;
    $replace = iter(gen { yield 99 });
}
is_deeply(\@seen, [1, 2], 'reassigning the source variable does not redirect a loop');

$calls = 0;
is_deeply([map { is($calls, $_, 'map input is pulled lazily'); ($_ * 2, $_ * 3) }
           iter(sub { ++$calls }, 4)], [2, 3, 4, 6, 6, 9],
          'map collects each block result');
is(scalar(map { ($_, $_) } iter(gen { return (1, 2, 3) })), 6,
   'scalar map counts output values');
is_deeply([map { () } iter(gen { return (1, 2, 3) })], [],
          'map may return no values on every iteration');
is_deeply([map { () } 1 .. 10], [], 'ordinary empty map remains safe');

$calls = 0;
is_deeply([grep { is($calls, $_, 'grep input is pulled lazily'); $_ % 2 }
           iter(sub { ++$calls }, 5)], [1, 3], 'grep retains accepted inputs');
is(scalar(grep { $_ % 2 } iter(gen { return (1, 2, 3) })), 2,
   'scalar grep counts accepted inputs');
is_deeply([grep { $_ *= 10; 1 } iter(gen { return (1, 2) })], [10, 20],
          'grep returns edits to its current input');
is_deeply([map { my $n = $_; map { $n + $_ } iter(gen { return (10, 20) }) }
           iter(gen { return (1, 2) })], [11, 21, 12, 22],
          'nested lazy maps have independent state');

$_ = 'outer';
eval { my @ignored = map { die "body failed\n" } iter(gen { yield 1 }) };
like("$@", qr/body failed/, 'map propagates a body exception');
is($_, 'outer', 'map restores the outer topic after an exception');
eval { my @ignored = grep { 1 } iter(sub { die "producer failed\n" }, undef) };
like("$@", qr/producer failed/, 'grep propagates a producer exception');
is($_, 'outer', 'grep restores the outer topic after a producer exception');

my @producer_topics;
my $topic_calls = 0;
my @accepted = grep { ++$_; 1 } iter(sub {
    push @producer_topics, $_;
    $_ = 'producer';
    ++$topic_calls;
}, 3);
is_deeply(\@accepted, [2, 3], 'producer writes cannot change accepted grep inputs');
is_deeply(\@producer_topics, ['outer', 'producer', 'producer'],
          'each producer call sees the enclosing topic');

'outside' =~ /(outside)/;
my $capture_calls = 0;
my @captures = map { $1 } iter(sub {
    'inside' =~ /(inside)/;
    ++$capture_calls;
}, 3);
is_deeply(\@captures, ['outside', 'outside'], 'producer matches do not replace caller captures');
is($1, 'outside', 'caller captures survive the consumer');

my @single = (iter(gen { return (4, 5) }));
@seen = ();
push @seen, $_ for @single;
is_deeply(\@seen, [4, 5], 'sole adapter in an array follows the list path');
my $stored = iter(gen { yield 9 });
@seen = ();
push @seen, $_ for (1, $stored, 2);
is_deeply(\@seen, [1, $stored, 2], 'mixed list retains an adapter as an ordinary value');
my @indexed;
for my ($index, $value) (indexed($stored)) { push @indexed, $index, $value }
is_deeply(\@indexed, [0, $stored], 'indexed optimization does not consume a stored adapter');

{
    package IterTied;
    sub TIESCALAR { bless [$_[1]], $_[0] }
    sub FETCH { $_[0][0] }
}
tie my $tied, 'IterTied', $stored;
my $previous = $tied;
(tied $tied)->[0] = 77;
is_deeply([map { $_ } $tied], [77], 'a tied scalar with a stale adapter reference is ordinary data');
(tied $tied)->[0] = gen { return (6, 7) };
is_deeply([map { $_ } iter($tied)], [6, 7], 'explicit iter snapshots a tied source');

our @shrinking = ($stored, 42);
@seen = ();
for (reverse @shrinking) {
    push @seen, $_;
    pop @shrinking if @seen == 1;
}
is_deeply(\@seen, [42, $stored], 'shrinking an array cannot turn a mixed list into an iterator source');

@seen = ();
for my ($a, $b) (iter(gen { return (1, 2, 3) })) { push @seen, $a, $b }
is_deeply(\@seen, [1, 2, 3, undef], 'multi-variable for pads the final group');
@seen = ();
$calls = 0;
for (iter(sub { ++$calls }, -1)) { push @seen, $_; last if $_ == 3 }
is_deeply(\@seen, [1, 2, 3], 'last can terminate an infinite source');

for my $consumer ('map', 'grep') {
    $calls = 0;
    my $unbounded = iter(sub { ++$calls }, -1);
    OUTER: for (1) {
        if ($consumer eq 'map') {
            map { last OUTER if $_ == 3; $_ } $unbounded;
        }
        else {
            grep { last OUTER if $_ == 3; 1 } $unbounded;
        }
    }
    is($calls, 3, "$consumer stops pulling when its body leaves the enclosing loop");
}

{
    package IterLifetime;
    our ($live, $maximum) = (0, 0);
    sub new {
        ++$live;
        $maximum = $live if $live > $maximum;
        return bless {}, shift;
    }
    sub DESTROY { --$live }
}
for my $consumer ('map', 'grep') {
    $IterLifetime::maximum = 0;
    my $n = 0;
    my $input = iter(sub { ++$n <= 1000 ? IterLifetime->new : undef }, undef);
    if ($consumer eq 'map') { map { $_ } $input }
    else { grep { 1 } $input }
    is($IterLifetime::live, 0, "void $consumer releases its inputs");
    cmp_ok($IterLifetime::maximum, '<=', 2,
           "void $consumer retains bounded input storage");
}

done_testing;
