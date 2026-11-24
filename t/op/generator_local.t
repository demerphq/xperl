#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
}
use strict;
use warnings;
use generator;
use B ();
use Config;
use builtin 'weaken';
no warnings 'experimental::builtin';

our ($slot, $other, $ambient) = ('root', 'other root', 'global');
sub owner {
    gen {
        local $slot = shift;
        my $ref = \$slot;
        yield $ref;
        $slot .= ' resumed';
        return $ref;
    };
}
my $root_ref = \$slot;
my ($a, $b) = (owner(), owner());
my $first = $a->('first');
my $second = $b->('second');
is($slot, 'root', 'both suspended owners expose the root binding');
ok(\$slot == $root_ref, 'the root scalar keeps its identity');
ok($first != $second && $first != $root_ref, 'the owners have their own scalar bindings');
$$second = 'edited';
{
    local $slot = 'different host';
    my $host_ref = \$slot;
    ok($a->() == $first, 'older owner resumes with its original scalar');
    is($$first, 'first resumed', 'resuming the older owner updates its saved reference');
    is($slot, 'different host', 'completion restores this caller');
    ok(\$slot == $host_ref, 'completion restores this caller by identity');
}
ok($b->() == $second, 'completing the older owner leaves the younger binding intact');
is($$second, 'edited resumed', 'an external write to the parked scalar survives');
ok(\$slot == $root_ref, 'both owners retire without replacing the root scalar');

my ($outer_ref, $inner_ref);
my $nested = gen {
    local $slot = 'outer';
    $outer_ref = \$slot;
    {
        local $slot = 'inner';
        $inner_ref = \$slot;
        yield $slot;
        $slot .= ' changed';
    }
    yield $slot;
    return $slot;
};
is($nested->(), 'inner', 'innermost local wins before first yield');
is($slot, 'root', 'suspension removes both nested locals');
{
    local $slot = 'host';
    my $host = \$slot;
    is($nested->(), 'outer', 'ordinary inner scope exit restores its outer local');
    is($$inner_ref, 'inner changed', 'inner assignment reached its own scalar');
    is($$outer_ref, 'outer', 'inner assignment left outer binding intact');
    ok(\$slot == $host, 'second suspension exposes its current caller');
}
is($nested->(), 'outer', 'last resume reinstalls just the surviving local');
is($slot, 'root', 'outer retirement exposes root');

my $child = gen {
    local $slot = 'child';
    yield "$slot/$ambient";
    yield "$slot/$ambient";
    return "$slot/$ambient";
};
my $parent = gen {
    local $slot = 'parent';
    local $ambient = 'parent ambient';
    my $from_child = $child->();
    yield "$slot/$from_child";
    my $last = $child->();
    return "$slot/$last";
};
is($parent->(), 'parent/child/parent ambient', 'child inherits the running parent environment');
{
    local $ambient = 'second caller';
    is($child->(), 'child/second caller', 'unlocalized variable follows a different resumer');
    is($slot, 'root', 'resuming a child leaves its parked parent detached');
}
is($parent->(), 'parent/child/parent ambient', 'the parent owns its local across direct child resumes');

{
    package LocalTestTie;
    sub TIESCALAR { bless [$_[1], $_[2]], $_[0] }
    sub FETCH { push @{$_[0][1]}, 'fetch'; $_[0][0] }
    sub STORE { push @{$_[0][1]}, 'store'; $_[0][0] = $_[1] }
}
{
    package LocalTestGuard;
    sub DESTROY { $_[0][0]->() }
}
{
    package LocalTestObject;
    sub DESTROY { ++${$_[0][0]} }
}
for my $end (qw(return fail abandon)) {
    my ($weak_object, @seen);
    my $destroyed = 0;
    my $g = gen {
        local $slot = 'owner';
        local $other = bless [\$destroyed], 'LocalTestObject';
        $weak_object = $other;
        weaken($weak_object);
        my $guard = bless [sub { push @seen, $slot }], 'LocalTestGuard';
        yield 'parked';
        die "owner failure\n" if $end eq 'fail';
        return $slot;
    };
    is($g->(), 'parked', "$end parks owner and resource");
    ok(defined($weak_object) && !@seen, "$end does not run cleanup at yield");
    {
        local $slot = 'host';
        my $host = \$slot;
        if ($end eq 'abandon') {
            undef $g;
        } elsif ($end eq 'fail') {
            eval { scalar $g->() };
            like("$@", qr/owner failure/, 'uncaught exception propagated');
        } else {
            is($g->(), 'owner', 'ordinary return ran in its private environment');
        }
        is(join(',', @seen), 'owner', "$end destructor saw the local before its scope exited");
        ok(\$slot == $host && $slot eq 'host', "$end preserved the host binding");
    }
    ok(!defined($weak_object) && $destroyed == 1, "$end released the localized object once");
}

for my $end (qw(return abandon)) {
    my $g = gen { local $slot = 'private'; yield $slot; yield $slot; return $slot };
    is($g->(), 'private', "$end starts before caller installs tie");
    my @calls;
    tie $slot, 'LocalTestTie', 'tied caller', \@calls;
    is($g->(), 'private', "$end can temporarily displace an opaque tied caller binding");
    if ($end eq 'return') {
        is($g->(), 'private', 'return restores the tied caller');
    } else {
        undef $g;
    }
    is(join(',', @calls), '', "$end switching and restoration called no tie methods");
    my $visible = $slot;
    is($visible, 'tied caller', "$end left the caller tie intact");
    is(join(',', @calls), 'fetch', "$end only the explicit read invoked FETCH");
    untie $slot;
    $slot = 'root';
}

our $absent;
for my $end (qw(return abandon)) {
    $absent = 'initial host';
    my $g = gen { local $absent = 'private'; yield $absent; yield $absent; return $absent };
    is($g->(), 'private', "$end plain binding parked before host slot removal");
    undef *absent;
    # *absent{SCALAR} would create an undef scalar, changing this test.
    my $gv = B::svref_2object(\*absent);
    is(ref($gv->SV), 'B::SPECIAL', "$end host GV starts with an absent scalar slot");
    is($g->(), 'private', "$end generator reinstalls its binding over absence");
    is(ref($gv->SV), 'B::SPECIAL', "$end a second yield restores absence");
    if ($end eq 'return') {
        is($g->(), 'private', 'normal return after absent host');
    } else {
        undef $g;
    }
    is(ref($gv->SV), 'B::SPECIAL', "$end cleanup restores an absent slot without vivifying it");
}

sub check_unavailable {
    my ($error, $label) = @_;
    like("$error", qr/generator continuation is not available/, $label);
}
for my $when (qw(before_first_yield after_first_yield)) {
    my (@seen, @calls);
    my $g = gen {
        local $slot = 'active';
        yield 'first' if $when eq 'after_first_yield';
        local $other = 'plain';
        tie $other, 'LocalTestTie', 'tied', \@calls;
        my $guard = bless [sub { push @seen, [$slot, !!tied($other)] }], 'LocalTestGuard';
        yield 'unexpected';
    };
    if ($when eq 'after_first_yield') {
        is($g->(), 'first', 'plain record first crosses yield');
    }
    eval { scalar $g->() };
    check_unavailable($@, "$when rejects an active tied local");
    ok($g->failed, "$when failed during execution");
    ok(@seen == 1 && $seen[0][0] eq 'active' && $seen[0][1],
       "$when rejection left private bindings installed for normal unwind");
    is($slot, 'root', "$when restored caller's plain binding");
    is($other, 'other root', "$when restored caller's second binding");
}

{
    my (@calls, @seen);
    my $g = gen {
        local $slot = 'outer';
        {
            local $slot = 'inner';
            yield 'both parked';
            tie $slot, 'LocalTestTie', 'private tie', \@calls;
            my $guard = bless [sub { push @seen, !!tied($slot) }], 'LocalTestGuard';
            yield 'unexpected';
        }
    };
    is($g->(), 'both parked', 'two plain locals on one slot cross yield');
    eval { scalar $g->() };
    check_unavailable($@, 'reject tying the innermost already converted local');
    ok(@seen == 1 && $seen[0], 'failed yield left the inner tie installed until scope exit');
    ok(\$slot == $root_ref && $slot eq 'root', 'neither nested record leaked into the caller');
}

for my $kind (qw(glob_slot foreach)) {
    my @seen;
    my $g = gen {
        local $slot = 'outer';
        if ($kind eq 'glob_slot') {
            my $target = 'alias';
            local *slot = \$target;
            my $guard = bless [sub { push @seen, $slot }], 'LocalTestGuard';
            yield 'unexpected';
        } else {
            for $slot ('alias') {
                my $guard = bless [sub { push @seen, $slot }], 'LocalTestGuard';
                yield 'unexpected';
            }
        }
    };
    eval { scalar $g->() };
    check_unavailable($@, "$kind rejects overlapping ownership of a scalar slot");
    is(join(',', @seen), 'alias', "$kind failed before exchanging any bindings");
    ok(\$slot == $root_ref && $slot eq 'root', "$kind restored the caller");
}

our ($left, $right) = ('left root', 'right root');
sub pair_owner {
    gen {
        local $left = 'left owner';
        local $right = 'right owner';
        yield 'started';
        return "$left/$right";
    };
}
sub transient_argument {
    my ($weak, $counter) = @_;
    my $object = bless [$counter], 'LocalTestObject';
    $$weak = $object;
    weaken($$weak);
    return $object;
}
{
    local *left = *right;
    my $host = \$right;
    my $g = pair_owner();
    is($g->(), 'started', 'two names for one ordinary slot can suspend');
    ok(\$left == $host && \$right == $host && $right eq 'right root',
       'suspension restored the shared original slot');
    {
        local *left;
        $left = 'split caller';
        eval { scalar $g->() };
        check_unavailable($@, 'resume rejects a formerly shared slot split into two');
        ok(\$left != $host && $left eq 'split caller' && \$right == $host,
           'rejecting the split leaves both caller bindings intact');
    }
    is($g->(), 'right owner/right owner', 'both names resolve to the innermost binding');
    ok(\$left == $host && \$right == $host, 'completion restored the alias by identity');
}
for my $end (qw(retry abandon)) {
    my $g = pair_owner();
    is($g->(), 'started', "$end suspends with two independent slots");
    {
        local *left = *right;
        my $aliased = \$right;
        my ($argument, $released) = (undef, 0);
        eval { scalar $g->(transient_argument(\$argument, \$released)) };
        check_unavailable($@, "$end rejects a caller that merged the two glob slots");
        ok(!defined($argument) && $released == 1, "$end rejected resume releases its argument");
        ok(!$g->failed && !$g->completed, "$end leaves the generator retryable");
        ok(\$left == $aliased && \$right == $aliased && $right eq 'right root',
           "$end rejection leaves the current alias binding untouched");
        if ($end eq 'abandon') {
            undef $g;
            ok(\$left == $aliased && \$right == $aliased && $right eq 'right root',
               'abandonment preserves the merged caller binding');
        }
    }
    if ($end eq 'retry') {
        is($g->(), 'left owner/right owner', 'retry succeeds when the original slot partition returns');
    }
    is("$left/$right", 'left root/right root', "$end structural cleanup preserved both ordinary bindings");
}

{
    my $g = gen {
        local $left = 'left owner';
        local $right = 'right owner';
        yield 'first';
        yield 'second';
        return "$left/$right";
    };
    is($g->(), 'first', 'owner awaits a resume argument');
    my ($reentry_error, $destroyed);
    {
        local *left;
        $left = 'temporary caller';
        is($g->(bless [sub {
            ++$destroyed;
            eval { scalar $g->() };
            $reentry_error = "$@";
            *left = *right;
        }], 'LocalTestGuard'), 'second', 'owner parks with the old argument');
        my ($argument, $released) = (undef, 0);
        eval { scalar $g->(transient_argument(\$argument, \$released)) };
        check_unavailable($@, 'caller aliases changed while replacing the old argument');
        like($reentry_error, qr/no suspended continuation/, 'old argument cannot recursively resume its owner');
        is($destroyed, 1, 'old argument was destroyed once');
        ok(!defined($argument) && $released == 1, 'late rejection releases the incoming argument');
        ok(\$left == \$right && $right eq 'right root', 'late rejection preserved the new caller alias');
    }
    is($g->(), 'left owner/right owner', 'owner can resume after the alias-changing destructor has run');
}

{
    my ($weak, $destroyed) = (undef, 0);
    my $g = gen {
        local $left = bless [\$destroyed], 'LocalTestObject';
        $weak = $left;
        weaken($weak);
        yield 'resource';
        return 1;
    };
    is($g->(), 'resource', 'a single ordinary localized resource parks');
    {
        local $_ = 'host topic';
        local *left = *main::_;
        my $topic = \$_;
        eval { scalar $g->() };
        my $error = $@;
        my $same_after_rejection = \$left == $topic && \$_ == $topic && $_ eq 'host topic';
        undef $g;
        my $same_after_drop = \$left == $topic && \$_ == $topic && $_ eq 'host topic';
        check_unavailable($error, 'a formerly ordinary GV now aliases a special GV');
        ok($same_after_rejection && $same_after_drop,
           'rejecting and dropping the owner leave the caller topic intact');
    }
    ok(!defined($weak) && $destroyed == 1, 'discard releases both parked references to the resource');
    is($left, 'left root', 'leaving the caller alias scope restores the original glob');
}

{
    # Generate package names so each wide scope really localizes distinct
    # glob slots. Every eighth entry shadows slots zero and one again.
    { package LocalGrowth; our ($alias, $v0) }
    my @names = map { "LocalGrowth::v$_" } 0 .. 79;
    my @root_values = map { "root $_" } 0 .. $#names;
    my $read_refs = sub {
        no strict 'refs';
        return [map { \${$_} } @names];
    };
    my $roots = $read_refs->();
    ${$roots->[$_]} = $root_values[$_] for 0 .. $#names;
    local *LocalGrowth::alias = *LocalGrowth::v0;
    my $mixed_order = sub {
        my @order;
        for my $index (@_) {
            push @order, $index;
            push @order, 'alias', 1 if $index % 8 == 0;
        }
        return @order;
    };
    my @first = $mixed_order->(0 .. $#names);
    my @second = $mixed_order->(reverse 24 .. 55);
    my $var_list = sub {
        return join ', ', map { $_ eq 'alias' ? '$LocalGrowth::alias'
                                              : '$' . $names[$_] } @_;
    };
    my @first_values = map { "first $_" } 0 .. $#first;
    my @second_values = map { "second $_" } 0 .. $#second;
    my $source = sprintf <<'OWNER', $var_list->(@first), $var_list->(@second);
        gen {
            local $LocalGrowth::v0 = 'anchor';
            yield $read_refs->();
            yield $read_refs->();
            {
                local (%s) = @first_values;
                yield $read_refs->();
                yield $read_refs->();
            }
            yield $read_refs->();
            yield $read_refs->();
            {
                local (%s) = @second_values;
                yield $read_refs->();
                yield $read_refs->();
            }
            return $LocalGrowth::v0;
        }
OWNER
    my $g = eval $source;
    die $@ unless $g;
    for my $phase (['initial binding', [], []],
                   ['first wide scope', \@first, \@first_values],
                   ['single surviving binding', [], []],
                   ['overlapping second scope', \@second, \@second_values]) {
        my ($label, $order, $values) = @$phase;
        my @expected = @root_values;
        $expected[0] = 'anchor';
        for my $i (0 .. $#$order) {
            my $index = $order->[$i] eq 'alias' ? 0 : $order->[$i];
            $expected[$index] = $values->[$i];
        }
        my $before = $g->();
        my $after = $g->();
        ok(eq_array([map { $$_ } @$after], \@expected), "$label preserves each visible binding");
        ok(!(grep { $before->[$_] != $after->[$_] } 0 .. $#names),
           "$label reinstalls the same scalars on resume");
        my $caller = $read_refs->();
        ok(!(grep { $caller->[$_] != $roots->[$_] } 0 .. $#names)
           && eq_array([map { $$_ } @$caller], \@root_values),
           "$label restores all caller slots");
    }
    is($g->(), 'anchor', 'leaving the second wide scope reveals the original outer local');
}

SKIP: {
    skip 'requires interpreter threads', 7 unless $Config{useithreads};
    require threads;
    my $wrapper;
    my $g = gen {
        local $slot = 'resumed owner';
        yield 'parked';
        my $seen = threads->create(sub {
            my ($parent_generator) = @_;
            my $value = $slot;
            $slot = 'child edit';
            return [$value, !defined iterator::state($parent_generator)];
        }, $wrapper)->join;
        yield [@$seen, $slot];
        return $slot;
    };
    $wrapper = $g;
    weaken($wrapper);
    is($g->(), 'parked', 'plain local crosses yield before interpreter cloning');
    my $values = $g->();
    is($values->[0], 'resumed owner', 'thread sees the binding installed at clone time');
    ok($values->[1], 'thread receives no runnable parent generator');
    is($values->[2], 'resumed owner', 'child assignment leaves the resumed parent binding intact');
    ok(\$slot == $root_ref && $slot eq 'root', 'parent caller regains its scalar after the next yield');
    is($g->(), 'resumed owner', 'parent generator retains its binding through completion');
    ok(\$slot == $root_ref && $slot eq 'root', 'completion restores the original caller binding');
}

done_testing;
