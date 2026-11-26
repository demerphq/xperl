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
    local $/ = 'outside';
    my $make = sub {
        my ($separator) = @_;
        gen {
            local $/ = $separator;
            yield $/;
            my $text = 'a|b,c';
            open my $fh, '<', \$text or die $!;
            yield scalar <$fh>;
            return $/;
        };
    };
    my ($a, $b) = ($make->('|'), $make->(','));
    is($a->(), '|', 'first owner selects its separator');
    is($/, 'outside', 'yield restores caller separator');
    is($b->(), ',', 'second owner selects another separator');
    $/ = 'caller edit';
    is($a->(), 'a|', 'readline uses first owner separator after resumption');
    is($b->(), 'a|b,', 'readline uses second owner separator after resumption');
    is($a->(), '|', 'older owner completes with its own separator');
    is($b->(), ',', 'younger owner completes with its own separator');
    is($/, 'caller edit', 'completion preserves later caller writes');
}

for my $key (qw(__DIE__ __WARN__ __EXCEPT__)) {
    local $SIG{$key};
    my $host = sub { };
    my $owner = sub { };
    $SIG{$key} = $host;
    my $g = gen {
        local $SIG{$key} = $owner;
        yield $SIG{$key};
        return $SIG{$key};
    };
    ok($g->() == $owner, "$key owner installs its hook");
    ok($SIG{$key} == $host, "$key caller reads its own hook while parked");
    ok($g->() == $owner, "$key owner reads its hook after resumption");
    ok($SIG{$key} == $host, "$key caller retains its hook after completion");
    for my $value (undef, 'DEFAULT', 'IGNORE') {
        $SIG{$key} = $value;
        my $g = gen {
            local $SIG{$key};
            delete $SIG{$key};
            yield exists $SIG{$key} ? 'exists' : 'absent';
            return exists $SIG{$key} ? 'exists' : 'absent';
        };
        is($g->(), 'absent', "$key owner can delete its hook");
        ok(exists $SIG{$key}, "$key caller key existence survives owner deletion");
        is($SIG{$key}, $value, "$key caller value survives owner deletion");
        is($g->(), 'absent', "$key deletion survives owner resumption");
    }
    delete $SIG{$key};
    my $missing = gen { local $SIG{$key} = $owner; yield 'ready'; return 'done' };
    is($missing->(), 'ready', "$key owner starts with absent caller key");
    ok(!exists $SIG{$key}, "$key caller key stays absent");
    is($missing->(), 'done', "$key owner finishes with absent caller key");
    ok(!exists $SIG{$key}, "$key completion preserves absence");
}

{
    my @events;
    local $SIG{__WARN__} = sub { push @events, 'caller warn' };
    local $SIG{__DIE__} = sub { push @events, 'caller die' };
    my $g = gen {
        local $SIG{__WARN__} = sub { push @events, 'owner warn' };
        local $SIG{__DIE__} = sub { push @events, 'owner die' };
        yield 'ready';
        warn "owner\n";
        eval { die "owner\n" };
        return 'done';
    };
    is($g->(), 'ready', 'hook owner suspends before delivery');
    warn "caller\n";
    eval { die "caller\n" };
    is($g->(), 'done', 'hook owner resumes for delivery');
    is(join(',', @events), 'caller warn,caller die,owner warn,owner die',
       'warn and die deliver to the active owner');
}

{
    my $key = 'generator_environment_probe';
    local $^H{$key} = 'host';
    my $make = sub {
        my ($name) = @_;
        gen { $^H{$key} = $name; yield $^H{$key}; return $^H{$key} };
    };
    my ($a, $b) = ($make->('A'), $make->('B'));
    is($a->(), 'A', 'first owner has private hints');
    is($b->(), 'B', 'second owner has private hints');
    is($^H{$key}, 'host', 'caller hints survive suspension');
    is($a->(), 'A', 'first hint survives resumption');
    is($b->(), 'B', 'second hint survives resumption');
    is($^H{$key}, 'host', 'caller hints survive completion');
    my $value = eval 'use feature "signatures"; sub ($x) { $x + 1 }->(41)';
    is($@, '', 'compiler state remains usable after hint switching');
    is($value, 42, 'eval uses its lexical feature settings');
}

{
    package EnvironmentGuard;
    sub DESTROY { $_[0][0]->() }
}
{
    local $/ = 'caller';
    my @seen;
    my $g = gen {
        local $/ = 'owner';
        my $guard = bless [sub { push @seen, $/ }], 'EnvironmentGuard';
        yield 'ready';
    };
    is($g->(), 'ready', 'abandoned owner suspends');
    undef $g;
    is(join(',', @seen), 'owner', 'abandonment reinstalls owner environment for cleanup');
    is($/, 'caller', 'abandonment restores caller environment');
    my $failed = gen { local $/ = 'failed'; yield 'ready'; die "failure\n" };
    is($failed->(), 'ready', 'failing owner suspends');
    eval { scalar $failed->() };
    like($@, qr/failure/, 'owner failure propagates');
    is($/, 'caller', 'failure restores caller environment');
}

{
    my ($host, $left, $right) = ('', '', '');
    open my $host_fh, '>', \$host or die $!;
    open my $left_fh, '>', \$left or die $!;
    open my $right_fh, '>', \$right or die $!;
    my $previous = select $host_fh;
    my $make = sub {
        my ($fh, $name) = @_;
        gen {
            select $fh;
            print "$name first;";
            yield $name;
            print "$name last;";
            return $name;
        };
    };
    my ($a, $b) = ($make->($left_fh, 'A'), $make->($right_fh, 'B'));
    my @values = ($a->(), $b->());
    print 'host;';
    push @values, scalar $a->(), scalar $b->();
    my $restored = select;
    select $previous;
    is(join(',', @values), 'A,B,A,B', 'output owners complete independently');
    is($host, 'host;', 'caller keeps its selected output');
    is($left, 'A first;A last;', 'first owner retains selected output');
    is($right, 'B first;B last;', 'second owner retains selected output');
    ok($restored == $host_fh, 'selected handle identity returns to caller');
}

{
    local $/ = "\n";
    my $g = gen {
        local $/ = \2;
        yield 'parked';
        my $text = 'abcdef';
        open my $fh, '<', \$text or die $!;
        return scalar <$fh>;
    };
    is($g->(), 'parked', 'fixed-length input owner suspends');
    is($g->(), 'ab', 'fixed-length input backing state survives suspension');
    is($/, "\n", 'fixed-length input restores caller mode');
}

{
    local $/ = 'host';
    my $child = gen { local $/ = 'child'; yield $/; return $/ };
    my $parent = gen {
        local $/ = 'parent';
        my $first = $child->();
        yield "$first/$/";
        return $/;
    };
    is($parent->(), 'child/parent', 'child returns to parent environment');
    is($/, 'host', 'nested suspension returns to host environment');
    is($child->(), 'child', 'child can finish directly in host');
    is($parent->(), 'parent', 'parent retains its environment after child completion');
    is($/, 'host', 'nested completion preserves host environment');
}

{
    no strict 'refs';
    local *{'main::/'} = *main::_;
    $_ = 'shared root';
    my $original = \$_;
    my $g = gen { yield 'parked'; return 'done' };
    is($g->(), 'parked', 'aliased default roots can suspend');
    ok(\$_ == $original && \$/ == $original, 'root exchanges restore original scalar identity');
    is($g->(), 'done', 'aliased default roots can finish');
    ok(\$_ == $original && \$/ == $original, 'completion preserves aliased root identity');
}

{
    no strict 'refs';
    local *main::SIG = *{"main::\cH"};
    my $original = \%SIG;
    my $g = gen { yield 'parked'; return 'done' };
    is($g->(), 'parked', 'aliased environment hashes can suspend');
    ok(\%SIG == $original && \%^H == $original, 'hash exchanges restore original identity');
    is($g->(), 'done', 'aliased environment hashes can finish');
    ok(\%SIG == $original && \%^H == $original, 'completion preserves aliased hash identity');
}

{
    require Hash::Util;
    local %SIG = %SIG;
    my $g = gen { local $SIG{__WARN__} = sub { }; yield 'parked'; return 'done' };
    is($g->(), 'parked', 'owner parks with a warning hook');
    delete $SIG{__WARN__};
    Hash::Util::lock_ref_keys(\%SIG);
    is($g->(), 'done', 'resuming does not insert keys into restricted caller hash');
    ok(!exists $SIG{__WARN__}, 'restricted caller retains absent hook');
    my $abandoned = gen { yield 'parked' };
    is($abandoned->(), 'parked', 'owner can start from restricted caller hash');
    undef $abandoned;
    pass('abandonment leaves restricted caller hash usable');
    Hash::Util::unlock_ref_keys(\%SIG);
}

{
    local %SIG = %SIG;
    $SIG{__WARN__} = sub { };
    my $g = gen { local $SIG{__WARN__}; delete $SIG{__WARN__}; yield 'parked'; return 'done' };
    is($g->(), 'parked', 'owner can remove its hook');
    ok((grep { $_ eq '__WARN__' } keys %SIG), 'keys exposes caller hook binding');
    is($g->(), 'done', 'owner with removed hook finishes');
    ok((grep { $_ eq '__WARN__' } keys %SIG), 'keys retains caller binding after completion');
}

SKIP: {
    require Config;
    skip 'requires WINCH', 5 unless $Config::Config{sig_name} =~ /\bWINCH\b/;
    local $SIG{WINCH};
    my @events;
    my $owner = sub { push @events, 'owner signal' };
    my $g = gen { $SIG{WINCH} = $owner; yield 'parked' };
    is($g->(), 'parked', 'native signal owner suspends');
    kill 'WINCH', $$;
    is(join(',', @events), 'owner signal', 'native signal delivery remains shared');
    undef $g;
    kill 'WINCH', $$;
    is(join(',', @events), 'owner signal,owner signal',
       'destroying private signal hash does not clear native disposition');
    delete $SIG{WINCH};
    my $missing = gen { yield 'parked'; return exists $SIG{WINCH} ? 'exists' : 'absent' };
    $SIG{WINCH} = $owner;
    is($missing->(), 'parked', 'owner starts after native key was absent');
    is($missing->(), 'exists', 'native key membership remains shared');
}

{
    package EnvironmentFetchFailure;
    sub TIESCALAR { bless [], $_[0] }
    sub FETCH { die "separator fetch failed\n" }
    sub STORE { }
}
{
    local $/;
    tie $/, 'EnvironmentFetchFailure';
    my $created = eval { gen { yield 'unused' } };
    my $error = $@;
    untie $/;
    ok(!$created, 'failed environment snapshot returns no generator');
    like($error, qr/separator fetch failed/, 'construction propagates magic failure');
}

{
    local $SIG{__WARN__};
    my $outer = sub { 'outer' };
    my $inner = sub { 'inner' };
    $SIG{__WARN__} = $outer;
    my $original = \%SIG;
    {
        local %SIG;
        $SIG{__WARN__} = $inner;
        ok($original->{__WARN__} == $outer, 'saved outer hash keeps its own hook binding');
    }
    ok($SIG{__WARN__} == $outer, 'whole-hash scope exit restores outer hook binding');
}

{
    my @seen;
    local $SIG{__WARN__} = sub { push @seen, 'outer' };
    my $outer = $SIG{__WARN__};
    my $outer_ref = \$SIG{__WARN__};
    my $escaped;
    {
        local $SIG{__WARN__} = sub { };
        $escaped = \$SIG{__WARN__};
        ok($escaped != $outer_ref, 'local hook has a distinct scalar inside its scope');
        ok($$outer_ref == $outer, 'local hook leaves held outer scalar unchanged');
    }
    $$escaped = sub { push @seen, 'escaped' };
    ok($SIG{__WARN__} == $outer, 'escaped element assignment does not replace current hash binding');
    warn "escaped hook\n";
    is(join(',', @seen), 'escaped', 'escaped magical element retains ordinary handler side effect');
}

{
    local %SIG = %SIG;
    delete $SIG{__EXCEPT__};
    Hash::Util::lock_ref_keys(\%SIG);
    %SIG = ();
    eval { $SIG{__EXCEPT__} = 'DEFAULT' };
    ok($@, 'clearing restricted hash does not approve an absent hook');
    Hash::Util::unlock_ref_keys(\%SIG);
}

{
    local %SIG = %SIG;
    $SIG{__WARN__} = 'DEFAULT';
    Hash::Util::lock_ref_keys(\%SIG);
    Hash::Util::lock_ref_value(\%SIG, '__WARN__');
    eval { %SIG = () };
    ok($@, 'restricted clear rejects a read-only hook value');
    ok(exists $SIG{__WARN__}, 'failed clear keeps the unchanged hook present');
    is($SIG{__WARN__}, 'DEFAULT', 'failed clear keeps the unchanged hook value');
    Hash::Util::unlock_ref_value(\%SIG, '__WARN__');
    Hash::Util::unlock_ref_keys(\%SIG);
}

{
    local $SIG{__EXCEPT__};
    delete $SIG{__EXCEPT__};
    my $g = gen { local $SIG{__EXCEPT__} = sub { }; yield 'parked' };
    is($g->(), 'parked', 'owner installs a hook absent from caller');
    is(scalar %SIG, scalar keys %SIG, 'scalar hash and scalar keys agree on active view');
    my %seen;
    while (my ($key, $value) = each %SIG) { $seen{$key} = $value }
    ok(!exists $seen{__EXCEPT__}, 'each omits a hook absent from caller');
}

{
    local $SIG{__WARN__} = sub { };
    my $host = $SIG{__WARN__};
    my $hook = sub { };
    my $g = gen {
        local $SIG{__WARN__};
        delete $SIG{__WARN__};
        my $ref = \$SIG{__WARN__};
        yield [exists $SIG{__WARN__}, $ref];
        yield [\$SIG{__WARN__} == $ref, defined $$ref];
        $$ref = $hook;
        return $SIG{__WARN__};
    };
    my $first = $g->();
    ok($first->[0], 'taking an element reference creates the owner key');
    ok($SIG{__WARN__} == $host, 'owner lvalue creation leaves caller hook alone');
    my $next = $g->();
    ok($next->[0] && !$next->[1], 'owner reference keeps scalar identity and undef value');
    ok($g->() == $hook, 'writing owner reference updates its handler');
    ok($SIG{__WARN__} == $host, 'reference-based update restores caller hook');
}

done_testing;
