#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use generator;

our ($alias, @alias, $other);
for my $operator (qw(map grep)) {
    for my $ending (qw(return abandon)) {
        local *main::_;
        local $_ = 'original';
        local $alias = 'outside';
        local @alias = ('caller arguments');
        my ($sv, $av) = (\$alias, \@alias);
        my $g = $operator eq 'map'
            ? gen { my @answer = map { yield $_; $_ } ('mapped'); return $answer[0] }
            : gen { my @answer = grep { yield $_; 1 } ('filtered'); return $answer[0] };
        my $expected = $operator eq 'map' ? 'mapped' : 'filtered';
        my $first = $g->();
        is($first, $expected, "$operator exposes the owner's topic");
        *main::_ = *alias;
        if ($ending eq 'return') {
            my ($last) = $g->();
            is($last, $expected, "$operator retains its item on resume");
        }
        else {
            undef $g;
        }
        my $same = \$_ == $sv && \$alias == $sv && \@_ == $av;
        my $visible = "$_/@_";
        ok($same, "$operator $ending preserves the caller's new glob binding");
        is($visible, 'outside/caller arguments',
           "$operator $ending leaves the caller's topic and arguments intact");
    }
}

{
    local *main::_;
    local $_ = 'original';
    local $alias = 'outside';
    local $other = 'other';
    my $sv = \$alias;
    my $g = gen {
        my @answer = map {
            my @inner = map {
                yield $_;
                *main::_ = *other;
                'done'
            } ('inner');
            yield $_;
            @inner;
        } ('outer');
        return $answer[0];
    };
    my $inner = $g->();
    is($inner, 'inner', 'inner map supplies its own topic');
    *main::_ = *alias;
    my $outer = $g->();
    is($outer, 'outer', 'inner map restores the outer topic after assigning to *_');
    my $same = \$_ == $sv;
    ok($same, 'second suspension preserves the glob selected by the caller');
    my ($result) = $g->();
    is($result, 'done', 'nested maps complete');
    $same = \$_ == $sv;
    ok($same, 'completion preserves the caller glob after both maps unwind');
}
done_testing();
