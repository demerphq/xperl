#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
}
use strict;
use warnings;
use feature qw(state lexical_subs);
use generator;
use B ();
use Config;
use builtin qw(weaken);
no warnings 'experimental::builtin';

sub factory {
    gen {
        my $saved = $_[0];
        my $reply = yield $saved;
        die "$saved failed\n" if defined($reply) && $reply eq 'fail';
        return $saved;
    };
}

for my $operation (qw(return destroy fail)) {
    my ($a, $b, $c, $d) = map { factory() } 1 .. 4;
    is($a->('A'), 'A', "$operation: first activation starts");
    is($b->('B'), 'B', "$operation: second activation starts");
    if ($operation eq 'destroy') {
        undef $a;
    }
    elsif ($operation eq 'fail') {
        eval { $a->('fail') };
        like("$@", qr/A failed/, 'an uncaught exception unwinds the older activation');
    }
    else {
        is($a->(), 'A', 'older activation completes first');
    }
    is($c->('C'), 'C', "$operation: a new activation starts");
    is($d->('D'), 'D', "$operation: another activation starts");
    is($b->(), 'B', "$operation: parked lexical was not reused");
}

# Obtain an OP_YIELD leaf without adding syntax or a public generator API.
# Its callers below are ordinary named Perl subs on the owner's private stack.
sub leaf_template {
    gen {
        my ($tag, $steps) = @_;
        for my $i (1 .. $steps) {
            my $reply = yield "$tag/$i";
            die "$tag failed\n" if defined($reply) && $reply eq 'fail';
        }
        return "$tag/done";
    };
}
my @template = B::svref_2object(\&leaf_template)->PADLIST->ARRAY;
my ($leaf_cv) = grep { ref($_) eq 'B::CV' } $template[1]->ARRAY;
my $leaf = $leaf_cv->object_2svref;

my $shared_outer = 0;
sub shared_frame {
    my ($leaf, $tag, $depth, $steps) = @_;
    state $sequence = 0;
    my $ticket = ++$sequence;
    my $local = "local-$tag";
    my $reply = $depth
        ? shared_frame($leaf, "$tag.inner", $depth - 1, $steps)
        : $leaf->($tag, $steps);
    ++$shared_outer;
    return join(':', $local, $_[1], $ticket, $sequence, $shared_outer, $reply);
}
sub owner_factory {
    gen { return shared_frame(@_) };
}

my ($first, $second, $third) = map { owner_factory() } 1 .. 3;
is($first->($leaf, 'A', 0, 1), 'A/1', 'first ordinary shared frame parks');
is($second->($leaf, 'B', 0, 1), 'B/1', 'second ordinary shared frame parks');
undef $first;
is($third->($leaf, 'C', 1, 1), 'C.inner/1', 'new recursive shared frames park');
is($second->(), 'local-B:B:2:4:1:B/done',
   'ordinary frame keeps its lexical, argument and ticket but shares state');
is($third->(), 'local-C:C:3:4:3:local-C.inner:C.inner:4:4:2:C.inner/done',
   'recursive frames retain separate values and share their captured lexical');

sub host_frame {
    my ($tag, $call) = @_;
    my $result = $call->();
    return "$tag|$_[0]|$result";
}
my $nested = gen { host_frame('parked', sub { $leaf->('nested', 1) }) };
is(host_frame('first host', sub { scalar $nested->() }),
   'first host|first host|nested/1', 'outside caller shares the parked CV');
my $host_result = host_frame('new host', sub {
    host_frame('recursive host', sub {
        my $result = $nested->();
        return "$result|" . B::svref_2object(\&host_frame)->DEPTH;
    });
});
is($host_result, 'new host|new host|recursive host|recursive host|parked|parked|nested/done|2',
   'resume restores the current outside padlist and depth');

sub alias_factory {
    gen {
        my $lexical = $_[0];
        my $argument = \$_[0];
        yield [\$lexical, $argument];
        return "$lexical/$$argument";
    };
}
my ($input_a, $input_b) = ('first', 'second');
my ($alias_a, $alias_b) = map { alias_factory() } 1 .. 2;
my $refs_a = $alias_a->($input_a);
my $refs_b = $alias_b->($input_b);
${$refs_a->[0]} = 'lexical changed';
$input_a = 'argument changed';
is($alias_a->(), 'lexical changed/argument changed', 'lexical references and argument aliases keep their identities');
is($alias_b->(), 'second/second', 'changing one activation leaves another intact');
is($refs_a->[1], \$input_a, 'the argument alias still refers to the caller scalar');

sub undef_target { my ($leaf) = @_; return $leaf->('undef', 1) }
my $protected = gen { undef_target($leaf) };
is($protected->(), 'undef/1', 'protected activation suspends');
eval { undef &undef_target };
like("$@", qr/undef.*active/i, 'a parked CV cannot be undefined');
is($protected->(), 'undef/done', 'failed undef leaves the parked body runnable');
eval { undef &undef_target };
is($@, '', 'completed contexts release their CV ownership');

sub callback_frame {
    my ($tag, $call) = @_;
    my $saved = $tag;
    my $result = $call->();
    return "$saved/$_[0]/$result";
}
my $callback_owner = gen {
    return callback_frame('parked', sub { $leaf->('callback', 1) });
};
is($callback_owner->(), 'callback/1', 'ordinary helper suspends');
is(callback_frame('ordinary', sub { 'immediate' }),
   'ordinary/ordinary/immediate', 'ordinary call uses its own activation');
is($callback_owner->(), 'parked/parked/callback/done',
   'ordinary call did not overwrite a suspended helper');

my $child = gen {
    return callback_frame('child', sub { $leaf->('child', 1) });
};
my $parent = gen {
    return callback_frame('parent', sub {
        my $value = $child->();
        $leaf->('parent', 1);
        return $value;
    });
};
is($parent->(), 'parent/1', 'parent and child park inside the same helper');
undef $parent;
is($child->(), 'child/child/child/done',
   'child survives destruction of its original caller');

sub package_helper { 'package sub' }
sub lexical_sub_factory {
    my $prefix = shift;
    gen {
        our sub package_helper;
        my $value = $prefix . $_[0];
        my sub lexical_reader { $value }
        my sub eval_reader { eval '$value' }
        yield [\&lexical_reader, \&eval_reader, sub { eval '$value' }];
        return package_helper();
    };
}
my ($outer_a, $outer_b) = map { lexical_sub_factory($_) } qw(A B);
my $read_a = $outer_a->(1);
my $read_b = $outer_b->(2);
is(join(',', map { $_->() } @$read_a), 'A1,A1,A1',
   'lexical and anonymous subs read their parked outer CV');
is(join(',', map { $_->() } @$read_b), 'B2,B2,B2',
   'a different outer CV has its own parked lexicals');
is($outer_a->(), 'package sub', 'our sub in a cloned pad calls the package sub');
undef $outer_a;
is($read_a->[0]->(), 'A1', 'escaped lexical sub keeps its captured value');
my @unavailable;
{
    local $SIG{__WARN__} = sub { push @unavailable, "$_[0]" };
    is($read_a->[1]->(), undef, 'eval cannot capture the retired lexical');
    is($read_a->[2]->(), undef, 'the retired lexical is unavailable to either eval');
}
like(join('', @unavailable), qr/Variable "\$value" is not available/,
     'string eval warns when the outer lexical is unavailable');
is($read_b->[1]->(), 'B2', 'retiring a different outer CV leaves this one available');

# A string eval looks up an ordinary named sub's current activation. Two
# closures with the same outside CV can therefore see the same activation.
sub eval_frame {
    my ($value, $publish, $run) = @_;
    $publish->(sub { eval '$value' });
    return $run->();
}
sub eval_owner {
    gen { return eval_frame(@_) };
}
my ($eval_a, $eval_b) = map { eval_owner() } 1 .. 2;
my ($lookup_a, $lookup_b);
is($eval_a->('first', sub { $lookup_a = shift }, sub { $leaf->('a', 2) }),
   'a/1', 'first shared outer CV parks');
is($eval_b->('second', sub { $lookup_b = shift }, sub { $leaf->('b', 1) }),
   'b/1', 'second shared outer CV parks');
is($lookup_a->(), 'second', 'string eval finds the most recently parked activation');
is(eval_frame('running', sub {}, $lookup_a), 'running', 'a running call takes precedence');
is($eval_a->(), 'a/2', 'older activation parks again');
is($lookup_b->(), 'first', 'parking again updates the lookup order');
is($eval_a->(), 'a/done', 'older activation returns');
is($lookup_a->(), 'second', 'the remaining parked activation is visible');
is($eval_b->(), 'b/done', 'last shared activation returns');

SKIP: {
    skip 'requires interpreter threads', 3 unless $Config{useithreads};
    require threads;
    my $owner = eval_owner();
    is($owner->('parent', sub {}, sub { $leaf->('thread', 1) }),
       'thread/1', 'parent owns a suspended call before cloning');
    my $child_error = threads->create(sub {
        eval { undef &eval_frame };
        return "$@";
    })->join;
    is($child_error, '', 'the child can undefine a sub parked only in the parent');
    is($owner->(), 'thread/done', 'child cleanup leaves the parent pad intact');
}

{
    package PadCleanup;
    sub DESTROY { ++${$_[0][0]} }
}
my $destroyed = 0;
sub resource_factory {
    gen {
        my ($counter, $tag) = @_;
        my $object = bless [$counter], 'PadCleanup';
        my $reply = yield $tag;
        die "$tag failed\n" if defined($reply) && $reply eq 'fail';
        return $tag;
    };
}
for my $operation (qw(return fail destroy)) {
    my ($a, $b) = map { resource_factory() } 1 .. 2;
    is($a->(\$destroyed, 'A'), 'A', "$operation: resource activation starts");
    is($b->(\$destroyed, 'B'), 'B', "$operation: second resource starts");
    my $before = $destroyed;
    if ($operation eq 'return') {
        is($a->(), 'A', 'resource activation completes');
    }
    elsif ($operation eq 'fail') {
        eval { $a->('fail') };
        like("$@", qr/A failed/, 'resource activation fails');
    }
    else {
        undef $a;
    }
    is($destroyed, $before + 1, 'only the older resource is destroyed');
    is($b->(), 'B', 'younger resource activation remains usable');
    is($destroyed, $before + 2, 'younger resource is destroyed on completion');
}

sub escaped_resource {
    gen {
        my $object = bless [$_[0]], 'PadCleanup';
        my sub object_reader { $object }
        yield [\&object_reader, sub { $object }];
        return;
    };
}
my $resource_owner = escaped_resource();
my $release_count = 0;
my $readers = $resource_owner->(\$release_count);
my $weak_object = $readers->[0]->();
weaken($weak_object);
undef $resource_owner;
is($readers->[1]->(), $weak_object, 'escaped subs share the captured object');
is($release_count, 0, 'escaped subs keep the object alive after its owner is dropped');
undef $readers;
ok(!defined($weak_object), 'dropping the escaped subs releases the object');
is($release_count, 1, 'the captured object is destroyed once');

my $cyclic = gen {
    my $holder = $_[0];
    yield $holder;
    return;
};
my $holder = { owner => $cyclic };
my $weak_owner = $cyclic;
weaken($weak_owner);
my $yielded_holder = $cyclic->($holder);
undef $cyclic;
ok(defined($weak_owner), 'an explicit reference cycle retains its owner');
delete $holder->{owner};
ok(!defined($weak_owner), 'breaking the cycle releases the suspended owner');
is($yielded_holder, $holder, 'yielding a reference preserves its identity');

# A deterministic local PRNG keeps the schedule reproducible and avoids
# depending on another test's calls to rand(). Mix depths, new invocations,
# normal returns, exceptions and abandonment while older frames remain live.
sub random_owner_factory {
    gen { return random_frame(@_) };
}
sub random_frame {
    my ($leaf, $tag, $depth, $steps) = @_;
    my $saved = $tag;
    my $reply = $depth ? random_frame($leaf, $tag, $depth - 1, $steps)
                       : $leaf->($tag, $steps);
    return $reply eq "$saved/done" ? $reply : "CORRUPTED:$saved:$reply";
}
for my $seed (1 .. 8) {
    my $state = $seed;
    my $next = sub { $state = (1664525 * $state + 1013904223) & 0xffffffff };
    my @active;
    my $serial = 0;
    for my $turn (1 .. 160) {
        if (!@active || $next->() % 4 == 0) {
            my $tag = "seed$seed.item" . ++$serial;
            my $depth = $next->() % 5;
            my $steps = 1 + $next->() % 4;
            my $context = random_owner_factory();
            is($context->($leaf, $tag, $depth, $steps), "$tag/1", "seed $seed turn $turn: start depth $depth");
            push @active, [$context, $tag, 1, $steps];
            next;
        }
        my $index = $next->() % @active;
        my $item = $active[$index];
        my ($context, $tag, $position, $steps) = @$item;
        my $operation = $next->() % 7;
        if (!$operation) {
            splice @active, $index, 1;
            next;
        }
        if ($operation == 1) {
            eval { $context->('fail') };
            like("$@", qr/\Q$tag\E failed/, "seed $seed turn $turn: exception");
            splice @active, $index, 1;
            next;
        }
        ++$item->[2];
        my $expected = $position == $steps ? "$tag/done" : "$tag/" . ($position + 1);
        is($context->(), $expected, "seed $seed turn $turn: resume");
        splice @active, $index, 1 if $position == $steps;
    }
    @active = ();
}

done_testing;
