#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;

{
    package TopicLocalGuard;
    sub DESTROY { $_[0]->() }
}
our $value;

for my $topic_first (0, 1) {
    my $locals = $topic_first
        ? q{local $_ = 'owner topic'; local $value = 'owner value';}
        : q{local $value = 'owner value'; local $_ = 'owner topic';};
    my $control = eval 'sub {' . $locals . 'return "' . '$value/$_' . '"; }';
    die $@ unless $control;
    my $expected;
    {
        local *value = *main::_;
        $expected = $control->();
    }
    for my $ending (qw(return fail abandon_before_resume abandon_after_resume)) {
        local *value;
        local *main::_;
        local $_ = 'caller topic';
        $value = 'caller value';
        my $outside_value = \$value;
        my $outside_topic = \$_;
        my @events;
        my $g = eval 'gen {' . $locals . <<'BODY';
            my $guard = bless sub {
                push @events, [$value, $_, \$value, \$_];
            }, 'TopicLocalGuard';
            yield [$value, $_, \$value, \$_];
            yield [$value, $_, \$value, \$_];
            die "owner failed\n" if $ending eq 'fail';
            return "$value/$_";
        }
BODY
        die $@ unless $g;
        my $first = $g->();
        is("$first->[0]/$first->[1]", 'owner value/owner topic',
           "$topic_first/$ending starts with separate bindings");
        ok($first->[2] != $first->[3], 'first yield retains distinct scalar identities');
        {
            local *value = *main::_;
            my $owned = $topic_first ? $first->[2] : $first->[3];
            $_ = 'edited caller';
            if ($ending ne 'abandon_before_resume') {
                my $resumed = $g->();
                is("$resumed->[0]/$resumed->[1]", $expected,
                   "$topic_first/$ending replay follows ordinary local order");
                ok($resumed->[2] == $owned && $resumed->[3] == $owned,
                   'merged names expose the original inner scalar');
            }
            if ($ending eq 'return') {
                is(scalar $g->(), $expected, 'return uses the ordered owner bindings');
            }
            elsif ($ending eq 'fail') {
                eval { scalar $g->() };
                like($@, qr/owner failed/, 'failure propagates from the owner');
            }
            undef $g;
            is(scalar @events, 1, "$ending destroys its guard once");
            is("$events[0][0]/$events[0][1]", $expected,
               "$topic_first/$ending cleanup follows ordinary local order");
            ok($events[0][2] == $owned && $events[0][3] == $owned,
               'cleanup observes the actual inner scalar through both names');
            ok(\$_ == $outside_topic && \$value == $outside_topic,
               'cleanup preserves the caller alias and scalar identity');
            is($_, 'edited caller', 'cleanup preserves the caller intervening write');
        }
        ok(\$value == $outside_value && $value eq 'caller value',
           'leaving caller alias scope restores its original value binding');
    }
}

{
    local *value = *main::_;
    local $_ = 'caller topic';
    my $outside = \$_;
    my ($outer, $inner, @seen);
    my $g = gen {
        local $_ = 'outer topic';
        $outer = \$_;
        local $value = 'inner value';
        $inner = \$value;
        my $guard = bless sub { push @seen, "$_/$value" }, 'TopicLocalGuard';
        yield [$_, $value, \$_, \$value];
        yield [$_, $value, \$_, \$value];
    };
    my $first = $g->();
    is("$first->[0]/$first->[1]", 'inner value/inner value',
       'owner created under a caller alias exposes the inner local');
    ok($outer != $inner && $first->[2] == $inner && $first->[3] == $inner,
       'hidden outer topic retains its own scalar');
    {
        local *value;
        $value = 'split caller';
        my $split = $g->();
        is("$split->[0]/$split->[1]", 'outer topic/inner value',
           'caller splitting the alias exposes both owner locals');
        ok($split->[2] == $outer && $split->[3] == $inner,
           'split replay preserves the hidden outer scalar identity');
        undef $g;
        is(join(',', @seen), 'outer topic/inner value', 'split cleanup sees both owner locals');
        is($value, 'split caller', 'split cleanup preserves caller value');
        ok(\$_ == $outside && $_ eq 'caller topic', 'split cleanup preserves caller topic');
    }
}

for my $operator (qw(map grep foreach given dispatch)) {
    my $body = $operator eq 'map' ? q{my @items = map { yield $_; $_ } (42);}
        : $operator eq 'grep' ? q{my @items = grep { yield $_; 1 } (42);}
        : $operator eq 'foreach' ? q{for (42) { yield $_ }}
        : $operator eq 'given' ? q{given (42) { yield $_ }}
        : q{dispatch (42) { on (_) { yield $_ } }};
    # The same local changes replay modes without leaving scope.
    my $g = eval q~use feature qw(switch dispatch_on);
        no warnings 'experimental::smartmatch';
        gen { local $_ = 'explicit'; local $value = 'ordinary';
            yield $_; ~ . $body . q~ yield $_; return $value; }~;
    die $@ unless $g;
    is(scalar $g->(), 'explicit', "$operator starts with an explicit topic local");
    is(scalar $g->(), 42, "$operator preserves its implicit topic handling");
    is(scalar $g->(), 'explicit', "$operator restores the explicit topic after its scope");
    is(scalar $g->(), 'ordinary', "$operator leaves the ordinary local intact");
}

{
    package TopicLocalTie;
    sub TIESCALAR { bless {value => $_[1], calls => $_[2]}, $_[0] }
    sub FETCH { push @{$_[0]{calls}}, 'fetch'; $_[0]{value} }
    sub STORE { push @{$_[0]{calls}}, 'store'; $_[0]{value} = $_[1] }
}
{
    my @calls;
    my $g = gen {
        tie $_, 'TopicLocalTie', 'outer', \@calls;
        {
            local $_ = 'inner';
            yield $_;
        }
        return $_;
    };
    is(scalar $g->(), 'inner', 'explicit topic local can displace a tied owner base');
    is(join(',', @calls), '', 'parking the topic calls no tie methods');
    is(scalar $g->(), 'outer', 'real scope exit restores the tied base');
    is(join(',', @calls), 'fetch', 'only the explicit read fetches the tied base');
}

{
    local *value;
    local *main::_;
    local $_ = 'caller topic';
    $value = 'caller value';
    my $caller = \$_;
    my $g = gen {
        local $value = 'owner value';
        yield 'first';
        *main::_ = *value;
        {
            local $_ = 'inner topic';
            yield $_;
        }
        yield 'topic scope ended';
        return 'done';
    };
    is(scalar $g->(), 'first', 'owner parks before outside slot removal');
    undef *value;
    is(scalar $g->(), 'inner topic', 'owner merges the topic with an absent outside slot');
    {
        local *value;
        $value = 'split caller';
        is(scalar $g->(), 'topic scope ended', 'topic restoration handles an absent base after splitting');
        ok(\$_ == $caller && $_ eq 'caller topic', 'absent-base restoration preserves caller topic identity');
        is($value, 'split caller', 'absent-base restoration preserves split caller value');
        is(scalar $g->(), 'done', 'owner completes after absent topic restoration');
    }
}

{
    no strict 'refs';
    local *main::_;
    local $_ = 'caller';
    my $topic = \$_;
    my $rs = \*{'main::/'};
    my $g = gen {
        $/ = '|';
        local $_ = '!';
        yield 'ready';
        my $text = 'a|b!';
        open my $fh, '<', \$text or die $!;
        return [$_, ${*{$rs}{SCALAR}}, scalar <$fh>];
    };
    is(scalar $g->(), 'ready', 'owner retains its original input-separator glob');
    {
        local $main::{'/'};
        delete $main::{'/'};
        my $replacement = \*{'main::/'};
        ok($replacement != $rs, 'the stash now holds a different separator glob');
        {
            local *main::_ = *$rs;
            my $base = \$_;
            my $ok = eval { scalar $g->(); 1 };
            ok(!$ok, 'topic alias to the retained separator rejects resume');
            like($@, qr/generator continuation is not available/,
                 'retained separator overlap reports a retryable conflict');
            ok(\$_ == $base, 'rejected replay leaves the retained separator scalar intact');
        }
        my $done = $g->();
        is(join('/', @$done), '!/|/a|', 'retry keeps the separator scalar and readline in agreement');
        ok(\$_ == $topic && $_ eq 'caller', 'retry preserves the caller topic');
    }
}

{
    my $g = gen { local $_ = 'owned'; yield 'ready'; return $_ };
    is(scalar $g->(), 'ready', 'owner parks before separator stash replacement');
    local $main::{'/'};
    delete $main::{'/'};
    my $replacement = sub () { 1234 };
    $main::{'/'} = $replacement;
    is(ref $main::{'/'}, 'CODE', 'replacement separator entry starts as a coderef');
    is(scalar $g->(), 'owned', 'owner resumes using its retained separator glob');
    is(ref $main::{'/'}, 'CODE', 'resume validation does not expand the caller stash entry');
    ok(ref $main::{'/'} eq 'CODE' && $main::{'/'} == $replacement,
       'resume preserves the caller replacement coderef');
}

{
    local *value;
    local *main::_;
    local $_ = 'caller topic';
    $value = 'caller value';
    my ($topic, $ordinary) = (\$_, \$value);
    my (@owners, @events);
    for my $topic_first (0, 1) {
        my $locals = $topic_first
            ? q{local $_ = "topic $name"; local $value = "value $name";}
            : q{local $value = "value $name"; local $_ = "topic $name";};
        my $factory = eval q~sub { my ($name, $events, $limit) = @_; gen {~
            . $locals . q~
                my $guard = bless sub { push @$events, [$name, $value, $_] },
                                  'TopicLocalGuard';
                my $step = 0;
                while ($step++ < $limit) {
                    yield ['yield', $value, $_, \$value, \$_];
                }
                return ['done', $value, $_, \$value, \$_];
            } }~;
        die $@ unless $factory;
        for my $number (1 .. 4) {
            my $name = "$topic_first/$number";
            my $g = $factory->($name, \@events, $number);
            my $first = $g->();
            push @owners, {g => $g, first => $first, name => $name,
                          topic_first => $topic_first};
        }
    }
    my $seed = 0x5eed;
    my $next = sub { $seed = ($seed * 1664525 + 1013904223) & 0xffffffff };
    my $step = 0;
    while (@owners && ++$step < 100) {
        my $index = $next->() % @owners;
        my $merged = $next->() & 1;
        my $abandon = $next->() % 5 == 0;
        $_ = "caller step $step";
        my $advance = sub {
            my $record = $owners[$index];
            my $name = $record->{name};
            my $inner = $record->{topic_first} ? "value $name" : "topic $name";
            my $expected = $merged ? "$inner/$inner" : "value $name/topic $name";
            my $before = @events;
            my $done = $abandon;
            if (!$abandon) {
                my $row = $record->{g}->();
                is("$row->[1]/$row->[2]", $expected,
                   "interleaved owner $name restores its current alias order");
                my ($left, $right) = $merged
                    ? (($record->{first}[$record->{topic_first} ? 3 : 4]) x 2)
                    : @{$record->{first}}[3, 4];
                ok($row->[3] == $left && $row->[4] == $right,
                   'interleaving preserves the original scalar objects');
                $done = $row->[0] eq 'done';
            }
            if ($done) {
                undef $record->{g};
                is(@events - $before, 1, 'interleaved termination cleans up once');
                is("$events[-1][1]/$events[-1][2]", $expected,
                   'interleaved cleanup uses the current owner bindings');
                splice @owners, $index, 1;
            }
            ok(\$_ == $topic && $_ eq "caller step $step",
               'interleaving preserves caller topic identity and writes');
            ok(\$value == ($merged ? $topic : $ordinary),
               'interleaving preserves the caller current alias topology');
        };
        if ($merged) { local *value = *main::_; $advance->() }
        else { $advance->() }
    }
    ok(!@owners, 'randomized owners complete or are abandoned within the bound');
}

done_testing;
