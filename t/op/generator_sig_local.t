#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use Config;
use generator;

my %number;
@number{split ' ', $Config{sig_name}} = split ' ', $Config{sig_num};
skip_all 'requires WINCH with its usual ignored default'
    unless $number{WINCH} && $Config{d_sigaction} && $Config{d_sigprocmask}
        && $^O =~ /\A(?:linux|darwin|freebsd|netbsd|openbsd|dragonfly)\z/;

my @heard;
sub handler {
    my ($label) = @_;
    return sub { push @heard, $label };
}

sub pulse {
    @heard = ();
    kill 'WINCH', $$ or die "kill WINCH failed: $!";
    return @heard ? join(',', @heard) : 'silent';
}

sub has_key { return exists $SIG{WINCH} ? 'present' : 'absent' }

sub owner {
    my ($id) = @_;
    return gen {
        local $SIG{WINCH} = handler($id);
        yield pulse();
        return pulse();
    };
}

{
    $SIG{WINCH} = handler('host');
    {
        local $SIG{WINCH} = handler('local');
        is(pulse(), 'local', 'control sends a real signal to the local handler');
    }
    is(pulse(), 'host', 'ordinary scope restores the host handler');
    my $g = gen {
        yield pulse();
        $SIG{WINCH} = handler('global');
        yield pulse();
        return pulse();
    };
    $SIG{WINCH} = handler('new host');
    is($g->(), 'new host', 'owner inherits the handler current at entry');
    is($g->(), 'global', 'ordinary assignment is effective immediately');
    is(pulse(), 'global', 'ordinary assignment stays global after suspension');
    $SIG{WINCH} = handler('caller edit');
    is($g->(), 'caller edit', 'an unlocalized owner sees a later caller assignment');
}

{
    $SIG{WINCH} = handler('host');
    my ($a, $b) = (owner('A'), owner('B'));
    is($a->(), 'A', 'A runs its handler');
    is(pulse(), 'host', 'caller handler is active after A yields');
    is($b->(), 'B', 'B runs its handler');
    is(pulse(), 'host', 'caller handler is active after B yields');
    $SIG{WINCH} = handler('edited');
    is($a->(), 'A', 'older owner resumes with A');
    is(pulse(), 'edited', 'older completion restores the caller edit');
    is($b->(), 'B', 'younger owner resumes with B');
    is(pulse(), 'edited', 'younger completion restores the caller edit');
}

{
    $SIG{WINCH} = handler('entry');
    my $g = gen {
        $SIG{WINCH} = handler('published');
        local $SIG{WINCH} = handler('owner');
        yield pulse();
        return pulse();
    };
    is($g->(), 'owner', 'local assignment takes precedence inside owner');
    is(pulse(), 'published', 'park exposes the assignment made before local');
    is($g->(), 'owner', 'resume reinstates local handler');
    is(pulse(), 'published', 'normal unwind retains the ordinary assignment');
}

{
    $SIG{WINCH} = handler('host');
    my $g = gen {
        local $SIG{WINCH} = handler('outer');
        yield pulse();
        {
            local $SIG{WINCH} = handler('inner');
            yield pulse();
            yield pulse();
        }
        return pulse();
    };
    is($g->(), 'outer', 'outer local installed');
    is(pulse(), 'host', 'first park removes the outer local');
    is($g->(), 'inner', 'inner local installed');
    is(pulse(), 'host', 'second park removes both locals');
    $SIG{WINCH} = handler('replacement');
    is($g->(), 'inner', 'resume restores the innermost local');
    is($g->(), 'outer', 'normal inner scope exit restores outer local');
    is(pulse(), 'replacement', 'outer scope exit restores latest caller handler');
}

{
    package ScopeWitness;
    sub DESTROY { my ($self) = @_; ${$self->[0]} = main::pulse() }
}

{
    $SIG{WINCH} = handler('host');
    my $seen;
    my $g = gen {
        local $SIG{WINCH} = handler('owner');
        my $guard = bless [\$seen], 'ScopeWitness';
        yield pulse();
    };
    is($g->(), 'owner', 'owner installed before parking');
    $SIG{WINCH} = handler('replacement');
    undef $g;
    is($seen, 'owner', 'lexical destructor runs under owner disposition');
    is(pulse(), 'replacement', 'caller disposition survives abandonment');
}

{
    delete $SIG{WINCH};
    my $g = owner('owner');
    is($g->(), 'owner', 'owner localizes a missing key');
    is(has_key(), 'absent', 'missing caller key is still absent while parked');
    is(pulse(), 'silent', 'missing caller action still ignores WINCH');
    $SIG{WINCH} = handler('added');
    is($g->(), 'owner', 'owner regains handler after caller creates key');
    is(pulse(), 'added', 'key created by the caller survives owner scope exit');

    $SIG{WINCH} = handler('host');
    my $d = gen {
        local $SIG{WINCH};
        delete $SIG{WINCH};
        yield join '/', has_key(), pulse();
        return join '/', has_key(), pulse();
    };
    is($d->(), 'absent/silent', 'local deletion removes key and disposition');
    is(has_key(), 'present', 'caller key survives suspended local deletion');
    is(pulse(), 'host', 'caller receives signal after local deletion');
    $SIG{WINCH} = handler('new host');
    is($d->(), 'absent/silent', 'resuming local deletion hides the new caller key');
    is(pulse(), 'new host', 'unwind restores caller replacement');
}

SKIP: {
    skip 'requires POSIX sigaction, SA_RESTART, USR1 and USR2', 5
        unless $Config{d_sigaction} && $number{USR1} && $number{USR2}
            && eval { require POSIX; POSIX::SA_RESTART() };
    delete $SIG{WINCH};
    $SIG{WINCH} = handler('baseline');
    my $set = sub {
        my ($label, $member, $restart) = @_;
        my $action = POSIX::SigAction->new(handler($label),
            POSIX::SigSet->new($number{$member}), $restart ? POSIX::SA_RESTART() : 0);
        $action->safe(1);
        defined POSIX::sigaction($number{WINCH}, $action) or die "sigaction: $!";
    };
    my $signature = sub {
        my $actual = POSIX::SigAction->new;
        defined POSIX::sigaction($number{WINCH}, undef, $actual) or die "sigaction: $!";
        return join '/', pulse(),
            ($actual->flags & POSIX::SA_RESTART() ? 'restart' : 'interrupt'),
            (grep { $actual->mask->ismember($number{$_}) } qw(USR1 USR2));
    };
    $set->('host', 'USR1', 1);
    is($signature->(), 'host/restart/USR1', 'control reads back the custom kernel action');
    my $g = gen {
        local $SIG{WINCH};
        $set->('owner', 'USR2', 0);
        yield $signature->();
        return $signature->();
    };
    is($g->(), 'owner/interrupt/USR2', 'owner installs distinct kernel action');
    is($signature->(), 'host/restart/USR1', 'park restores original mask, flag, and handler');
    $set->('new caller', 'USR1', 1);
    is($g->(), 'owner/interrupt/USR2', 'resume reinstalls owner mask, flag, and handler');
    is(pulse(), 'new caller', 'completion preserves latest caller handler');
}

{
    $SIG{WINCH} = handler('host');
    my $before = \$SIG{WINCH};
    my $g = gen {
        my $deleted = \(delete local $SIG{WINCH});
        return $deleted == $before && !exists $SIG{WINCH};
    };
    ok($g->(), 'synchronous delete local preserves scalar identity and absence');
    ok(\$SIG{WINCH} == $before, 'synchronous deletion restores its binding');

    for my $kind (qw(element hash glob)) {
        delete $SIG{WINCH};
        $SIG{WINCH} = handler('host');
        my $g = $kind eq 'element' ? gen {
            delete local $SIG{WINCH};
            yield 'park';
        } : $kind eq 'hash' ? gen {
            local %SIG;
            $SIG{WINCH} = handler('owner');
            yield 'park';
        } : gen {
            local *SIG;
            yield 'park';
        };
        eval { $g->() };
        like($@, qr/generator continuation is not available|unsupported localization/,
             "unsupported $kind signal localization rejects suspension");
        undef $g;
    }
    # Ordinary delete-local removes the restored scalar's signal magic.
    # Use a fresh entry for the independent signal checks below.
    delete $SIG{WINCH};
    ok(!exists $SIG{WINCH}, 'deleting a nonmagical restored value updates its journal cell');
}

SKIP: {
    skip 'requires CHLD and CLD spellings for the same signal', 6
        unless $number{CHLD} && $number{CLD} && $number{CHLD} == $number{CLD};
    local $SIG{CHLD} = handler('host');
    my $outside = \$SIG{CHLD};
    my $pulse = sub {
        @heard = ();
        kill 'CHLD', $$ or die "kill CHLD failed: $!";
        return join ',', @heard;
    };
    my $g = gen {
        local $SIG{CLD} = handler('owner');
        my $read = $SIG{CHLD};
        yield $pulse->();
        $read = $SIG{CHLD};
        return $pulse->();
    };
    is($g->(), 'owner', 'alternate signal spelling reads owner handler');
    is($pulse->(), 'host', 'alias read leaves saved effective handler intact');
    ok(\$SIG{CHLD} == $outside, 'alias read preserves caller scalar identity');
    $SIG{CHLD} = handler('replacement');
    is($g->(), 'owner', 'alias owner resumes independently of caller edit');
    is($pulse->(), 'replacement', 'alias completion restores current caller action');
    ok(\$SIG{CHLD} == $outside, 'alias completion preserves caller scalar identity');
}

{
    $SIG{WINCH} = handler('host');
    my $g = gen {
        local $SIG{WINCH} = handler('owner');
        yield pulse();
        die "owner failure\n";
    };
    is($g->(), 'owner', 'failing owner suspends with its handler');
    $SIG{WINCH} = handler('replacement');
    eval { $g->() };
    like($@, qr/owner failure/, 'owner failure propagates');
    is(pulse(), 'replacement', 'failure restores the current caller action');
}

{
    $SIG{WINCH} = handler('host');
    my $child = gen {
        local $SIG{WINCH} = handler('child');
        yield pulse();
        return pulse();
    };
    my $parent = gen {
        local $SIG{WINCH} = handler('parent');
        my $first = $child->();
        yield join '/', $first, pulse();
        return pulse();
    };
    is($parent->(), 'child/parent', 'nested suspension reinstalls parent handler');
    is(pulse(), 'host', 'parent suspension reinstalls host handler');
    is($child->(), 'child', 'child can complete directly in the host');
    is(pulse(), 'host', 'child completion preserves host handler');
    is($parent->(), 'parent', 'parent retains handler after child completes');
    is(pulse(), 'host', 'nested completion restores host handler');
}

{
    my @owners = map { owner("owner $_") } 0 .. 15;
    my @steps = (0) x @owners;
    my @live = 0 .. $#owners;
    my $state = 1729;
    my $outside = 'initial caller';
    $SIG{WINCH} = handler($outside);
    while (@live) {
        $state = (25173 * $state + 13849) % 65536;
        my $selected = $state % @live;
        my $i = $live[$selected];
        if ($steps[$i] && $i % 3 == 0) {
            undef $owners[$i];
            splice @live, $selected, 1;
        }
        else {
            is($owners[$i]->(), "owner $i", 'randomly selected signal owner runs its handler');
            if ($steps[$i]++) {
                undef $owners[$i];
                splice @live, $selected, 1;
            }
        }
        is(pulse(), $outside, 'random interleaving preserves caller disposition');
        $outside = "caller $state";
        $SIG{WINCH} = handler($outside);
    }
}

done_testing;
