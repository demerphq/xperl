#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;
use builtin 'weaken';
no warnings 'experimental::builtin';

our (@value, %value, $value);
@value = ('host array');
%value = (name => 'host hash');
$value = 'host scalar';
my $root_array = \@value;
my $root_hash = \%value;

sub owner {
    my ($name) = @_;
    gen {
        local @value = ($name, undef);
        local %value = (name => $name, undefined => undef);
        yield [\@value, \%value];
        push @value, 'resumed';
        $value{resumed} = 1;
        return [\@value, \%value];
    };
}

{
    my ($a, $b) = (owner('A'), owner('B'));
    my $left = $a->();
    my $right = $b->();
    ok($left->[0] != $right->[0] && $left->[1] != $right->[1],
       'owners have distinct aggregate bindings');
    ok(\@value == $root_array && \%value == $root_hash,
       'suspension preserves caller aggregate identities');
    is("@value", 'host array', 'caller keeps its array contents');
    is($value{name}, 'host hash', 'caller keeps its hash contents');
    is($value, 'host scalar', 'array and hash locals leave the scalar slot alone');
    $left->[0][0] = 'edited A';
    $left->[1]{name} = 'edited A';
    ok(exists $left->[1]{undefined} && !defined $left->[1]{undefined},
       'undefined owner element stays present');
    ok(!exists $left->[1]{absent}, 'absent owner element stays absent');
    {
        local @value = ('another caller array');
        local %value = (name => 'another caller hash');
        my ($av, $hv) = (\@value, \%value);
        my $done = $a->();
        ok($done->[0] == $left->[0] && $done->[1] == $left->[1],
           'older owner resumes with the same AV and HV');
        is(join('/', @{$done->[0]}[0, 2]), 'edited A/resumed',
           'held array reference edits reach the resumed owner');
        is($done->[1]{name}, 'edited A', 'held hash reference edits reach the resumed owner');
        ok(\@value == $av && \%value == $hv,
           'completion restores the current caller identities');
        is("@value/$value{name}", 'another caller array/another caller hash',
           'completion restores the current caller values');
    }
    my $done = $b->();
    ok($done->[0] == $right->[0] && $done->[1] == $right->[1],
       'younger owner survives older completion');
    ok(\@value == $root_array && \%value == $root_hash,
       'both completions retain original root objects');
}

{
    my ($outer, $inner);
    my $g = gen {
        local @value = ('outer');
        local %value = (name => 'outer');
        $outer = [\@value, \%value];
        {
            local @value = ('inner');
            local %value = (name => 'inner');
            $inner = [\@value, \%value];
            yield "$value[0]/$value{name}";
        }
        yield "$value[0]/$value{name}";
        return [\@value, \%value];
    };
    is($g->(), 'inner/inner', 'nested localizations expose their inner bindings');
    ok(\@value == $root_array && \%value == $root_hash,
       'yield removes both nested binding layers');
    is($g->(), 'outer/outer', 'inner scope exit restores the owned outer aggregates');
    my $done = $g->();
    ok($done->[0] == $outer->[0] && $done->[1] == $outer->[1],
       'outer aggregate identities survive nested scope exit');
    is($inner->[0][0], 'inner', 'held inner array remains its own object');
    is($inner->[1]{name}, 'inner', 'held inner hash remains its own object');
}

{
    my $child = owner('child');
    my $parent = gen {
        local @value = ('parent');
        local %value = (name => 'parent');
        my $first = $child->();
        yield "$first->[0][0]/$value[0]/$value{name}";
        return "$value[0]/$value{name}";
    };
    is($parent->(), 'child/parent/parent', 'child suspension restores parent aggregates');
    is($child->()->[0][0], 'child', 'child can finish directly in the host');
    is($parent->(), 'parent/parent', 'parent retains its bindings after child completion');
    ok(\@value == $root_array && \%value == $root_hash,
       'nested execution restores host identities');
}

{
    package AggregateScopeWitness;
    sub DESTROY {
        my ($self) = @_;
        push @{$self->[0]}, "$main::value[0]/$main::value{name}";
    }
}

for my $ending (qw(return die abandon)) {
    my @seen;
    my $weak_array;
    my $weak_hash;
    my $g = gen {
        local @value = ("$ending array");
        local %value = (name => "$ending hash");
        $weak_array = \@value;
        $weak_hash = \%value;
        weaken($weak_array);
        weaken($weak_hash);
        my $guard = bless [\@seen], 'AggregateScopeWitness';
        yield 1;
        die "aggregate owner failure\n" if $ending eq 'die';
        return 1;
    };
    is($g->(), 1, "$ending owner suspends");
    ok(defined $weak_array && defined $weak_hash, "$ending journal keeps its aggregates alive");
    if ($ending eq 'abandon') {
        undef $g;
    }
    else {
        eval { $g->() };
        like($@, qr/aggregate owner failure/, 'aggregate owner failure propagates')
            if $ending eq 'die';
    }
    is(join(',', @seen), "$ending array/$ending hash",
       "$ending lexical cleanup runs with owner bindings");
    ok(!defined $weak_array && !defined $weak_hash, "$ending releases retired aggregates");
    ok(\@value == $root_array && \%value == $root_hash,
       "$ending preserves caller aggregate identities");
}

{
    package AggregateElementWitness;
    sub DESTROY {
        my ($self) = @_;
        my $current = $self->[1] eq 'array' ? $main::value[0] : $main::value{name};
        push @{$self->[0]}, defined $current ? $current : 'absent';
    }
}

sub ordinary_array_cleanup {
    my ($seen) = @_;
    local @value = ('outgoing array');
    push @value, bless [$seen, 'array'], 'AggregateElementWitness';
    return 1;
}
sub ordinary_hash_cleanup {
    my ($seen) = @_;
    local %value = (name => 'outgoing hash');
    $value{witness} = bless [$seen, 'hash'], 'AggregateElementWitness';
    return 1;
}

for my $kind (qw(array hash)) {
    my (@expected, @seen);
    if ($kind eq 'array') { ordinary_array_cleanup(\@expected) }
    else { ordinary_hash_cleanup(\@expected) }
    my $g = $kind eq 'array' ? gen {
        local @value = ('outgoing array');
        push @value, bless [\@seen, 'array'], 'AggregateElementWitness';
        yield 1;
    } : gen {
        local %value = (name => 'outgoing hash');
        $value{witness} = bless [\@seen, 'hash'], 'AggregateElementWitness';
        yield 1;
    };
    is($g->(), 1, "$kind owner suspends before element cleanup");
    $g->();
    is(join(',', @seen), join(',', @expected),
       "$kind element destruction keeps ordinary decrement-before-restore order");
}

{
    my $g = gen {
        local @value = ('A', 'B', 'C');
        local %value = (A => 1, B => 2, C => 3);
        my $length = \$#value;
        my $av = \@value;
        weaken($av);
        my @first_array = each @value;
        my @first_hash = each %value;
        yield [$first_array[0], $first_hash[0]];
        my @next_array = each @value;
        my @next_hash = each %value;
        return [$next_array[0], $next_hash[0], $$length, defined $av];
    };
    my $first = $g->();
    each @value;
    each %value;
    my $next = $g->();
    is($next->[0], $first->[0] + 1, 'array iterator belongs to its AV across suspension');
    isnt($next->[1], $first->[1], 'hash iterator belongs to its HV across suspension');
    is($next->[2], 2, 'array length reference stays bound to its owned AV');
    ok($next->[3], 'array backreference bookkeeping survives suspension');
}

{
    my @owners = map { owner("owner $_") } 0 .. 15;
    my @steps = (0) x @owners;
    my @refs;
    my @live = 0 .. $#owners;
    my $state = 1729;
    while (@live) {
        $state = (25173 * $state + 13849) % 65536;
        my $selected = $state % @live;
        my $i = $live[$selected];
        if ($steps[$i] && $i % 3 == 0) {
            undef $owners[$i];
            splice @live, $selected, 1;
        }
        else {
            my $current = $owners[$i]->();
            is($current->[0][0], "owner $i", 'random owner keeps its array contents');
            is($current->[1]{name}, "owner $i", 'random owner keeps its hash contents');
            if ($steps[$i]++) {
                ok($current->[0] == $refs[$i][0] && $current->[1] == $refs[$i][1],
                   'random completion retains both object identities');
                undef $owners[$i];
                splice @live, $selected, 1;
            }
            else {
                $refs[$i] = $current;
            }
        }
        ok(\@value == $root_array && \%value == $root_hash,
           'random interleaving preserves host identities');
    }
}

{
    my $g = gen {
        local $value = 'scalar';
        local @value = ('array');
        local %value = (name => 'hash');
        yield "$value/$value[0]/$value{name}";
        return "$value/$value[0]/$value{name}";
    };
    is($g->(), 'scalar/array/hash', 'one glob has independent scalar, array and hash locals');
    is($value, 'host scalar', 'mixed suspension restores scalar binding');
    is($g->(), 'scalar/array/hash', 'mixed bindings resume independently');
    ok(\@value == $root_array && \%value == $root_hash,
       'mixed completion restores both aggregate roots');
}

{
    our (@alias_left, %alias_left, @alias_right, %alias_right);
    local *alias_left;
    local *alias_right;
    @alias_left = ('outside left');
    %alias_left = (name => 'outside left');
    @alias_right = ('outside right');
    %alias_right = (name => 'outside right');
    my ($left_av, $left_hv) = (\@alias_left, \%alias_left);
    my ($right_av, $right_hv) = (\@alias_right, \%alias_right);
    my $g = gen {
        local @alias_left = ('owner');
        local %alias_left = (name => 'owner');
        yield [\@alias_left, \%alias_left];
        return [\@alias_left, \%alias_left];
    };
    my $owned = $g->();
    *alias_left = *alias_right;
    my $done = $g->();
    ok($done->[0] == $owned->[0] && $done->[1] == $owned->[1],
       'ordinary glob retargeting preserves owned aggregate identities');
    ok(\@alias_left == $right_av && \%alias_left == $right_hv,
       'retargeted completion restores the current glob slots');
    is($left_av->[0], 'outside left', 'retargeting leaves held original array untouched');
    is($left_hv->{name}, 'outside left', 'retargeting leaves held original hash untouched');
}

{
    our (@absent_array, %absent_hash);
    local *absent_array;
    local *absent_hash;
    my $g = gen {
        local @absent_array = ('owner');
        local %absent_hash = (name => 'owner');
        yield 1;
        return "$absent_array[0]/$absent_hash{name}";
    };
    is($g->(), 1, 'owner suspends before caller slots are removed');
    undef *absent_array;
    undef *absent_hash;
    is($g->(), 'owner/owner', 'resumption can replace absent caller slots');
    ok(!defined *absent_array{ARRAY}, 'completion preserves an absent caller array slot');
    ok(!defined *absent_hash{HASH}, 'completion preserves an absent caller hash slot');
}

for my $change (qw(merge split)) {
    our (@merge_left, %merge_left, @merge_right, %merge_right);
    our (@merge_third, %merge_third);
    local *merge_left;
    local *merge_right;
    local *merge_third;
    @merge_left = ('host left');
    %merge_left = (name => 'host left');
    @merge_right = ('host right');
    %merge_right = (name => 'host right');
    @merge_third = ('host third');
    %merge_third = (name => 'host third');
    *merge_right = *merge_left if $change eq 'split';
    my $g = gen {
        local @merge_left = ('left');
        local %merge_left = (name => 'left');
        local @merge_right = ('right');
        local %merge_right = (name => 'right');
        yield 1;
        yield "$merge_left[0]/$merge_right[0]/$merge_left{name}/$merge_right{name}";
        return 1;
    };
    is($g->(), 1, "$change owner parks with both aggregate localizations");
    if ($change eq 'merge') { *merge_left = *merge_right }
    else { *merge_left = *merge_third }
    my @outside = (\@merge_left, \@merge_right, \%merge_left, \%merge_right);
    is($g->(), $change eq 'merge' ? 'right/right/right/right' : 'left/right/left/right',
       "$change replays both saves through the current typed slots");
    ok(\@merge_left == $outside[0] && \@merge_right == $outside[1]
       && \%merge_left == $outside[2] && \%merge_right == $outside[3],
       "$change suspension restores current caller identities");
    is($g->(), 1, "$change owner completes");
    ok(\@merge_left == $outside[0] && \@merge_right == $outside[1]
       && \%merge_left == $outside[2] && \%merge_right == $outside[3],
       "$change completion restores current caller identities");
}

{
    our (@special_scalar_glob, %special_scalar_glob);
    no strict 'refs';
    local *special_scalar_glob = *{'main::@'};
    @special_scalar_glob = ('outside array');
    %special_scalar_glob = (name => 'outside hash');
    my ($av, $hv) = (\@special_scalar_glob, \%special_scalar_glob);
    my $g = gen {
        local @special_scalar_glob = ('owner array');
        local %special_scalar_glob = (name => 'owner hash');
        yield "$special_scalar_glob[0]/$special_scalar_glob{name}";
        return "$special_scalar_glob[0]/$special_scalar_glob{name}";
    };
    is($g->(), 'owner array/owner hash', 'aggregate slots can share a glob with a special scalar');
    ok(\@special_scalar_glob == $av && \%special_scalar_glob == $hv,
       'special scalar root does not interfere with aggregate suspension');
    is($g->(), 'owner array/owner hash', 'aggregate slots on a special scalar glob resume');
    ok(\@special_scalar_glob == $av && \%special_scalar_glob == $hv,
       'special scalar root does not interfere with aggregate completion');
}

require Tie::Array;
require Tie::Hash;
for my $kind (qw(array hash)) {
    my $g = $kind eq 'array' ? gen {
        local @value = ('owner');
        yield \@value;
        return \@value;
    } : gen {
        local %value = (name => 'owner');
        yield \%value;
        return \%value;
    };
    my $owned = $g->();
    if ($kind eq 'array') { tie @$owned, 'Tie::StdArray' }
    else { tie %$owned, 'Tie::StdHash' }
    eval { $g->() };
    like($@, qr/generator continuation is not available|unsupported localization/,
         "$kind changed to a tied aggregate cannot resume");
    ok(\@value == $root_array && \%value == $root_hash,
       "rejected $kind resumption leaves caller bindings alone");
    if ($kind eq 'array') { untie @$owned }
    else { untie %$owned }
    ok($g->() == $owned, "$kind resumption can be retried after untie");
}

{
    my $g = gen {
        local %AggregateLocalStash::;
        yield 1;
    };
    eval { $g->() };
    like($@, qr/generator continuation is not available|unsupported localization/,
         'a package symbol table cannot cross a yield');
}

{
    our @inheritance;
    local *inheritance = *AggregateLocalProbe::ISA;
    my $g = gen {
        local @inheritance = ('Some::Parent');
        yield 1;
    };
    eval { $g->() };
    like($@, qr/generator continuation is not available|unsupported localization/,
         'an ISA alias with MRO effects cannot cross a yield');
}

{
    our @retargeted;
    local *retargeted;
    local *AggregateLocalInheritance::ISA;
    @retargeted = ('host');
    my $outside = \@retargeted;
    my $g = gen {
        local @retargeted = ('Some::Parent');
        yield 1;
        return 1;
    };
    is($g->(), 1, 'ordinary array parks before special-slot retargeting');
    {
        undef *AggregateLocalInheritance::ISA;
        local *retargeted = *AggregateLocalInheritance::ISA;
        eval { $g->() };
        like($@, qr/generator continuation is not available|unsupported localization/,
             'retargeting to an absent ISA slot cannot resume');
    }
    is($g->(), 1, 'resumption can be retried after leaving the ISA alias');
    ok(\@retargeted == $outside, 'retry preserves original caller array identity');
}

{
    package AggregateOtherPackage;
    sub owner {
        gen {
            local @AggregateOtherPackage::items = ('array');
            local %AggregateOtherPackage::SIG = (name => 'hash');
            local %AggregateOtherPackage::ENV = (name => 'environment');
            yield "$AggregateOtherPackage::items[0]/$AggregateOtherPackage::SIG{name}/$AggregateOtherPackage::ENV{name}";
            return 'done';
        };
    }
}
{
    @AggregateOtherPackage::items = ('caller');
    %AggregateOtherPackage::SIG = (name => 'caller');
    %AggregateOtherPackage::ENV = (name => 'caller');
    my @outside = (\@AggregateOtherPackage::items, \%AggregateOtherPackage::SIG,
                   \%AggregateOtherPackage::ENV);
    my $g = AggregateOtherPackage::owner();
    is($g->(), 'array/hash/environment', 'ordinary global names in another package can suspend');
    ok(\@AggregateOtherPackage::items == $outside[0]
       && \%AggregateOtherPackage::SIG == $outside[1] && \%AggregateOtherPackage::ENV == $outside[2],
       'package-local SIG and ENV names do not alias the special hashes');
    is($g->(), 'done', 'another package owner completes');
}

sub helper_with_local_aggregates {
    local @value = ('helper');
    local %value = (name => 'helper');
    return "$value[0]/$value{name}";
}
{
    my $g = gen {
        my $from_helper = helper_with_local_aggregates();
        yield $from_helper;
    };
    is($g->(), 'helper/helper', 'helper locals can end before the generator yields');
    ok(\@value == $root_array && \%value == $root_hash,
       'helper return leaves the generator and host bindings intact');
}

done_testing;
