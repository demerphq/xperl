#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
    require './test.pl';
}

use iterator;
use generator;

plan tests => 18;

my @items = qw(one two three);
my $index = 0;
my $iterator = iterator->new(sub {
    CORE::__SUB__->set_state(iterator::COMPLETED) if $index == $#items;
    return $items[$index++];
});

is(ref($iterator), 'iterator', 'iterator is a blessed coderef');
ok(ref($iterator) eq 'iterator', 'iterator remains a code reference');
ok($iterator->running, 'new iterator is running');
is($iterator->state, iterator::RUNNING, 'new iterator has running state');
is($iterator->(), 'one', 'iterator returns its first value');
ok($iterator->running, 'iterator remains running before final value');
is($iterator->(), 'two', 'iterator returns its second value');
is($iterator->(), 'three', 'iterator returns its final value');
ok($iterator->completed, 'iterator can mark itself completed');
ok($iterator->exhausted, 'completed iterator is exhausted');
is(iterator::state($iterator), iterator::COMPLETED,
   'state package function works');
ok(!iterator::running($iterator), 'running package function sees completion');

iterator::set_state($iterator, iterator::RUNNING);
ok($iterator->running, 'package setter changes iterator state');
$iterator->set_state(iterator::COMPLETED);
ok($iterator->completed, 'method setter changes iterator state');

my $generator = gen { yield 1 };
ok($generator->isa('iterator'), 'generator inherits from iterator');
ok(iterator::running($generator), 'iterator predicate accepts generators');
is(iterator::state($generator), iterator::RUNNING,
   'iterator state maps generator suspension state');
eval { $generator->set_state(iterator::COMPLETED) };
like($@, qr/cannot set the state of a generator/,
     'ordinary iterator setter cannot modify a generator');
