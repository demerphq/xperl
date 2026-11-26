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
for my $kind (qw(glob foreach)) {
    our ($left, $right);
    local *left;
    local *right;
    $left = 'left root';
    $right = 'right root';
    my $g = gen {
        local $left = 'private';
        if ($kind eq 'glob') {
            local *right;
            $right = 'private glob';
            yield 'parked';
        }
        else {
            for $right ('private loop') {
                yield 'parked';
            }
        }
        return $left;
    };
    if ($kind eq 'glob') {
        eval { scalar $g->() };
        like($@, qr/unsupported localization/, 'whole glob local prevents yield');
        is("$left/$right", 'left root/right root', 'rejected glob local unwinds normally');
        next;
    }
    is($g->(), 'parked', "$kind save initially uses a different slot");
    {
        local *left = *right;
        if ($kind eq 'foreach') {
            is($g->(), 'private', 'merged loop and scalar bindings unwind in scope order');
            ok($g->completed, 'merged loop owner completes');
        }
        else {
            eval { scalar $g->() };
            check_unavailable($@, "rebind detects new overlap with an owner's $kind save");
            ok(!$g->failed, "$kind overlap leaves the owner retryable");
        }
    }
    is($g->(), 'private', "$kind owner resumes after removing the unsupported overlap")
        if $kind eq 'glob';
    is("$left/$right", 'left root/right root', "$kind completion restores the caller");
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
    like("$error", qr/generator continuation is not available|unsupported localization/, $label);
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

{
    my (@calls, @errors);
    my $weak_packet;
    my $g = gen {
        eval {
            local $other = 'plain';
            tie $other, 'LocalTestTie', 'tied', \@calls;
            my $packet = bless {}, 'LocalTestPacket';
            $weak_packet = $packet;
            weaken($weak_packet);
            yield $packet;
        };
        push @errors, $@;
        yield 'valid';
        return 'finished';
    };
    is($g->(), 'valid', 'a caught park failure does not deliver its rejected packet');
    check_unavailable($errors[0], 'the owner catches its park failure');
    ok(!defined($weak_packet), 'the rejected packet is released before the next suspension');
    is($g->(), 'finished', 'the handler can continue to normal completion');
    is($other, 'other root', 'caught rejection restores the caller binding');
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
    if ($kind eq 'foreach') {
        is($g->(), 'unexpected', 'nested loop and scalar local can suspend');
        is(join(',', @seen), '', 'suspending loop does not run cleanup');
        undef $g;
    }
    else {
        eval { scalar $g->() };
        check_unavailable($@, "$kind rejects overlapping ownership of a scalar slot");
    }
    is(join(',', @seen), 'alias', "$kind cleanup sees its own binding");
    ok(\$slot == $root_ref && $slot eq 'root', "$kind restored the caller");
}

our ($left, $right) = ('left root', 'right root');
sub pair_owner {
    my ($events, $finish) = @_;
    gen {
        local $left = 'left owner';
        local $right = 'right owner';
        my $guard = $events
            ? bless([sub { push @$events, "$left/$right" }], 'LocalTestGuard')
            : undef;
        yield 'started';
        die "alias failure\n" if defined($finish) && $finish eq 'fail';
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

# Ordinary scalar restoration follows the current glob, including its aliases.
for my $layout (qw(merged split)) {
    our (@left, @right);
    local *left;
    local *right;
    $left = 'left host';
    $right = 'right host';
    @left = ('left array');
    @right = ('right array');
    *left = *right if $layout eq 'split';
    my $g = gen {
        local $left = 'left owner';
        local $right = 'right owner';
        yield 'arrays parked';
        return [$left, $right, $left[0], $right[0]];
    };
    is($g->(), 'arrays parked', "$layout array view starts before caller rebinding");
    if ($layout eq 'merged') {
        *left = *right;
        is(join('/', @{$g->()}), 'right owner/right owner/right array/right array',
           'scalar replay leaves merged caller array slots in place');
    }
    else {
        local *left;
        $left = 'split host';
        @left = ('new array');
        is(join('/', @{$g->()}), 'left owner/right owner/new array/right array',
           'scalar replay leaves split caller array slots in place');
    }
}
{
    local *left;
    local *right;
    $left = 'bar';
    $right = 'baz';
    my ($old_left, $old_right) = (\$left, \$right);
    my $g = gen {
        local $left = 'foo';
        *left = *right;
        yield "$left/$right";
        return "$left/$right";
    };
    is($g->(), 'baz/baz', 'an owner can alias its localized name before suspension');
    is("$left/$right", 'bar/bar', 'deactivation restores through the new alias like scope exit');
    is(\$right, $old_left, 'restoration installs the original scalar in the new shared slot');
    is($$old_right, 'baz', 'an escaped reference keeps the displaced scalar');
    is($g->(), 'baz/baz', 'reactivation restores the view from before suspension');
    is("$left/$right", 'bar/bar', 'completion follows the same alias as ordinary Perl');
    is(\$left, $old_left, 'completion preserves the restored scalar identity');
}
{
    local *left;
    local *right;
    $left = 'bar';
    $right = 'baz';
    {
        local $left = 'foo';
        local *left = *right;
        is("$left/$right", 'baz/baz', 'native local glob assignment aliases the slots');
    }
    is("$left/$right", 'bar/baz', 'native glob restoration precedes scalar restoration');
}
{
    my $g = gen {
        local $left = 'outer';
        my $outer = \$left;
        {
            local $right = 'inner';
            yield [$outer, \$right];
            yield "$left/$right";
        }
        yield "$left/$right";
        return "$left/$right";
    };
    my $private = $g->();
    {
        local *left = *right;
        my $host = \$right;
        $right = 'caller write';
        is($g->(), 'inner/inner', 'merged names see the innermost local');
        is(${$private->[0]}, 'outer', 'escaped outer scalar survives while hidden');
        $right = 'later write';
        is($g->(), 'outer/outer', 'leaving the inner scope exposes the outer binding');
        is($g->(), 'outer/outer', 'outer local remains visible until completion');
        is(\$right, $host, 'completion restores the current resumer scalar');
        is($right, 'later write', 'caller writes between suspensions are preserved');
    }
    $right = 'right root';
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
        is($g->(), 'left owner/right owner', 'resume follows a shared slot split into two');
        ok(\$left != $host && $left eq 'split caller' && \$right == $host,
           'completion restores both current caller bindings');
    }
    ok($g->completed, 'the split owner completed normally');
    ok(\$left == $host && \$right == $host, 'completion restored the alias by identity');
}
for my $end (qw(return fail abandon)) {
    my @seen;
    my $g = pair_owner(\@seen, $end);
    is($g->(), 'started', "$end suspends with two independent slots");
    {
        local *left = *right;
        my $aliased = \$right;
        if ($end eq 'return') {
            is($g->(), 'right owner/right owner', 'the inner local wins after merging slots');
        }
        elsif ($end eq 'fail') {
            eval { scalar $g->() };
            like("$@", qr/alias failure/, 'failure unwinds through the merged slots');
        }
        undef $g;
        is(join(',', @seen), 'right owner/right owner', "$end cleanup sees the current alias");
        ok(\$left == $aliased && \$right == $aliased && $right eq 'right root',
           "$end restores the merged caller binding by identity");
    }
    is("$left/$right", 'left root/right root', "$end structural cleanup preserved both ordinary bindings");
}

{
    my $g = gen { local $left = 'owner'; yield 'parked'; return $left };
    is($g->(), 'parked', 'owner parks before a resumer foreach');
    for $left ('resumer iterator') {
        is($g->(), 'owner', 'a resumer foreach does not conflict with owner saves');
        is($left, 'resumer iterator', 'completion preserves the resumer iteration binding');
    }
    is($left, 'left root', 'the resumer loop restores its own outside binding');
}
{
    local *left;
    local *right;
    $left = 'caller left';
    $right = 'caller right';
    my @calls;
    my $g = gen {
        local $left = 'owner left';
        local $right = 'owner right';
        yield 'parked';
        *left = *right;
        yield 'unsupported opaque merge';
    };
    is($g->(), 'parked', 'plain locals park before installing an opaque caller');
    tie $right, 'LocalTestTie', 'opaque caller', \@calls;
    eval { scalar $g->() };
    check_unavailable($@, 'an owner merge moving an opaque caller to an inner record is unsupported');
    ok($g->failed, 'unsupported opaque merge follows ordinary failure unwind');
    is(join(',', @calls), '', 'rejecting the opaque combination invokes no tie methods');
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
        is($g->(transient_argument(\$argument, \$released)), 'right owner/right owner',
           'replay follows aliases changed by an old argument destructor');
        like($reentry_error, qr/no suspended continuation/, 'old argument cannot recursively resume its owner');
        is($destroyed, 1, 'old argument was destroyed once');
        undef $g;
        ok(!defined($argument) && $released == 1, 'completion releases the incoming argument');
        ok(\$left == \$right && $right eq 'right root', 'completion preserved the new caller alias');
    }
    is("$left/$right", 'left root/right root', 'leaving the caller glob scope restores its names');
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
        is($g->(), 1, 'an ordinary local resumes through a new alias to the topic');
        my $same_after_completion = \$left == $topic && \$_ == $topic && $_ eq 'host topic';
        undef $g;
        my $same_after_drop = \$left == $topic && \$_ == $topic && $_ eq 'host topic';
        ok($same_after_completion && $same_after_drop,
           'completion and dropping the owner leave the caller topic intact');
    }
    ok(!defined($weak) && $destroyed == 1, 'completion releases the parked resource');
    is($left, 'left root', 'leaving the caller alias scope restores the original glob');
}

for my $ending (qw(return fail abandon)) {
    local *left;
    $left = 'outside left';
    local $_ = 'outside topic';
    my $topic = \$_;
    my @cleanup;
    my $g = gen {
        $_ = 'owner topic';
        local $left = 'private left';
        my $guard = bless [sub { push @cleanup, [$left, $_, \$left, \$_] }],
                          'LocalTestGuard';
        yield \$left;
        yield [$left, $_, \$left, \$_];
        die "topic owner failed\n" if $ending eq 'fail';
        return $left;
    };
    my $private = $g->();
    {
        local *left = *main::_;
        my $resumed = $g->();
        is("$resumed->[0]/$resumed->[1]", 'private left/private left',
           "$ending: local binding overrides the owner's topic root");
        ok($resumed->[2] == $private && $resumed->[3] == $private,
           "$ending: both names expose the original private scalar");
        ok(\$_ == $topic && $_ eq 'outside topic',
           "$ending: suspension restores the caller topic by identity");
        $_ = 'edited outside topic';
        if ($ending eq 'return') {
            is($g->(), 'private left', 'return resumes with the local binding');
        }
        elsif ($ending eq 'fail') {
            eval { scalar $g->() };
            like($@, qr/topic owner failed/, 'topic-alias failure propagates');
        }
        undef $g;
        is("$cleanup[0][0]/$cleanup[0][1]", 'private left/private left',
           "$ending: cleanup sees the owner's local through both names");
        ok($cleanup[0][2] == $private && $cleanup[0][3] == $private,
           "$ending: cleanup retains the private scalar identity");
        ok(\$_ == $topic && $_ eq 'edited outside topic',
           "$ending: cleanup preserves the caller's intervening write");
    }
    is($left, 'outside left', "$ending: caller glob scope restores its old slot");
}

for my $direction (qw(to_topic from_topic scalar_only)) {
    local *main::_;
    local @_ = ('caller first', 'caller second');
    local *left;
    $left = 'outside left';
    local $_ = 'outside topic';
    my $left_root = \$left;
    my $topic = \$_;
    my $arguments = \@_;
    my @outside_args = @_;
    my $g = gen {
        $_ = 'owner topic';
        local $left = 'private left';
        if ($direction eq 'to_topic') { *left = *main::_ }
        elsif ($direction eq 'from_topic') { *main::_ = *left }
        else { *left = \$_ }
        yield [$left, $_, \$left, \$_];
        return [$left, $_];
    };
    my $first = $g->('owner argument');
    my $value = $direction eq 'from_topic' ? 'private left' : 'owner topic';
    is("$first->[0]/$first->[1]", "$value/$value",
       "$direction: active alias has ordinary Perl's visible value");
    ok($first->[2] == $first->[3], "$direction: active values share their scalar");
    my $last = $g->();
    is("$last->[0]/$last->[1]", "$value/$value", "$direction: resumption preserves owner values");
    ok(\$_ == $topic && $_ eq 'outside topic', "$direction: return restores caller topic");
    if ($direction eq 'scalar_only') {
        ok(\$left == $left_root && $left eq 'outside left',
           'a scalar-only alias leaves two independently restored slots');
    }
    else {
        ok(\$left == $topic, "$direction: caller observes the explicit whole-glob alias");
    }
    ok(\@_ == $arguments, "$direction: caller argument array retains its identity");
    is(join(',', @_), join(',', @outside_args), "$direction: caller arguments retain their contents");
}

for my $topic_first (0, 1) {
    local *left;
    $left = 'outside left';
    local $_ = 'outside topic';
    my $locals = $topic_first
        ? q{local $_ = 'localized topic'; local $left = 'private left';}
        : q{local $left = 'private left'; local $_ = 'localized topic';};
    my $g = eval 'gen { ' . $locals . 'yield "parked"; return "$left/$_"; }';
    die $@ unless $g;
    is($g->(), 'parked', 'separate scalar and direct topic locals can park');
    {
        local *left = *main::_;
        my $topic = \$_;
        my $inner = $topic_first ? 'private left' : 'localized topic';
        is($g->(), "$inner/$inner", 'direct topic and scalar locals replay in scope order');
        ok(\$_ == $topic && $_ eq 'outside topic', 'ordered replay leaves caller intact');
    }
    ok($g->completed, 'owner with merged topic bindings completes');
}

{
    package LocalTopicArgument;
    sub TIESCALAR { bless $_[1], $_[0] }
    sub FETCH { $_[0][0]->(); return 'argument' }
}
{
    local *left;
    local $_ = 'outside topic';
    my @seen;
    my $g = gen {
        $_ = 'owner topic';
        local $left = 'private';
        my $value = yield 'parked';
        return "$left/$_/$value";
    };
    is($g->(), 'parked', 'argument test parks before aliasing to the topic');
    {
        local *left = *main::_;
        tie my $argument, 'LocalTopicArgument', [sub { push @seen, "$left/$_" }];
        is($g->($argument), 'private/private/argument', 'resume argument is fetched after replay');
    }
    is(join(',', @seen), 'private/private', 'argument FETCH sees the owner local and topic');
    is($_, 'outside topic', 'argument magic leaves the caller topic intact');
}

for my $name ('main::@', "main::\cERROR_OBJ") {
    local *left;
    my $g = gen { local $left = 'private'; yield 'parked'; return $left };
    is($g->(), 'parked', 'owner parks before aliasing to an error slot');
    {
        no strict 'refs';
        local *left = *{$name};
        my $error_slot = \$left;
        eval { scalar $g->() };
        check_unavailable($@, 'ordinary locals cannot replay through an error root');
        ok(\$left == $error_slot, 'rejection preserves the error slot identity');
    }
    is($g->(), 'private', 'owner retries after removing the error-root alias');
}

for my $kind (qw(given dispatch)) {
    local *left;
    $left = 'outside left';
    local $_ = 'outside topic';
    my $source = $kind eq 'given'
        ? q{use feature 'switch'; no warnings 'experimental::smartmatch';
            gen { local $left = 'private'; given ('inner topic') {
                yield 'parked'; return "$left/$_";
            } }}
        : q{use feature 'dispatch_on';
            gen { local $left = 'private'; dispatch ('inner topic') {
                on (_) { yield 'parked'; return "$left/$_" }
            } }};
    my $g = eval $source;
    die $@ unless $g;
    is($g->(), 'parked', "$kind topic owner parks with a separate scalar local");
    {
        local *left = *main::_;
        my $topic = \$_;
        eval { scalar $g->() };
        check_unavailable($@, "$kind topic save cannot overlap scalar replay");
        ok(\$_ == $topic && $_ eq 'outside topic', "$kind rejection preserves the caller");
    }
    is($g->(), 'private/inner topic', "$kind resumes after removing the overlap");
}

{
    local *left;
    local *right;
    my $g;
    {
        no strict 'refs';
        local *right = *{'main::@'};
        $g = gen {
            local $left = 'outer';
            local $right = 'inner';
            yield 'parked';
            return "$left/$right";
        };
        eval { scalar $g->() };
        like($@, qr/unsupported localization/,
             'an alias to an unmanaged error binding cannot cross yield');
        ok($g->failed, 'unsupported special alias fails during execution');
    }
}

{
    local *left;
    local $_ = 'outside topic';
    my $topic = \$_;
    my $g;
    {
        local *left = *main::_;
        $g = gen {
            local $left = 'private alias';
            yield \$left;
            return [$left, $_];
        };
        my $private = $g->();
        is($$private, 'private alias', 'ordinary topic alias can localize before the first yield');
        ok(\$_ == $topic && $_ eq 'outside topic', 'first park restores the caller topic');
    }
    my $last = $g->();
    is($last->[0], 'private alias', 'resumption follows the split ordinary slot');
    is($last->[1], 'outside topic', 'splitting the alias preserves the owner topic root');
    ok(\$_ == $topic && $_ eq 'outside topic', 'completion preserves caller topic identity');
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
