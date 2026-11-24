#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_dynamic_extension('B');
}
use strict;
use warnings;
use feature 'signatures';
use generator;
use B ();
use builtin qw(weaken);
no warnings 'experimental::builtin';

my %destroyed;
{
    package FrameResource;
    sub DESTROY { ++$destroyed{ $_[0][0] } }
}

sub leaf_template {
    gen {
        my ($tag, $steps) = @_;
        for my $iteration (1 .. $steps) {
            my $command = yield "$tag/$iteration";
            die "abort $tag\n" if defined($command) && $command eq 'abort';
        }
        return [$tag, []];
    }
}
my @template = B::svref_2object(\&leaf_template)->PADLIST->ARRAY;
my ($body) = grep { ref($_) eq 'B::CV' } $template[1]->ARRAY;
my $leaf = $body->object_2svref;

sub frame ($tag, $depth, $steps, $weak) {
    my $local = "$tag.$depth";
    my $resource = bless [$local], 'FrameResource';
    push @$weak, $resource;
    weaken($weak->[-1]);
    my $result = $depth ? frame($tag, $depth-1, $steps, $weak)
                        : $leaf->($tag, $steps);
    push @{$result->[1]}, [$local, $resource->[0], $depth];
    return $result;
}

sub owner { gen { return frame(@_) } }

sub exercise ($seed) {
    # 48271 is a Park-Miller multiplier. Divide before multiplying on 32-bit builds.
    my $state = $seed;
    my $roll = sub ($limit) {
        my $lo = $state % 44488;
        my $hi = int($state / 44488);
        $state = 48271 * $lo - 3399 * $hi;
        $state += 2147483647 if $state <= 0;
        return $state % $limit;
    };
    my @depths = (0, 1, 3, 8, 16);
    my (@parked, $serial);
    my %terminal;
    for my $turn (1 .. 220) {
        my $start = $turn < 185 && (!@parked || (@parked < 18 && $roll->(10) < 5));
        if ($start) {
            my $tag = "s$seed." . ++$serial;
            my $depth = $depths[$roll->(@depths + 0)];
            my $steps = 1 + $roll->(5);
            my @weak;
            my $g = owner();
            my $actual = $g->($tag, $depth, $steps, \@weak);
            die "start $tag: $actual" unless $actual eq "$tag/1" && @weak == $depth + 1;
            push @parked, { g=>$g, tag=>$tag, depth=>$depth, steps=>$steps, pos=>1, weak=>\@weak };
            next;
        }
        last unless @parked;
        my $index = $roll->(scalar @parked);
        my $p = $parked[$index];
        my ($g, $tag, $depth) = @$p{qw(g tag depth)};
        my $action = $turn >= 185 ? 0 : $roll->(10);
        if ($action == 0) {
            delete $p->{g};
            undef $g;
            ++$terminal{drop};
        }
        elsif ($action == 1) {
            my $unused = eval { scalar $g->('abort') };
            die "wrong exception for $tag: $@" unless "$@" =~ /abort \Q$tag\E\n/;
            ++$terminal{fail};
        }
        else {
            my $value = $g->();
            if (++$p->{pos} <= $p->{steps}) {
                die "resume $tag: wrong yield" unless $value eq "$tag/$p->{pos}";
                next;
            }
            die "wrong result for $tag" unless ref($value) eq 'ARRAY' && $value->[0] eq $tag;
            my @got = map { join '/', @$_ } @{$value->[1]};
            my @want = map { "$tag.$_/$tag.$_/$_" } 0 .. $depth;
            die "frames changed for $tag" unless "@got" eq "@want";
            ++$terminal{return};
        }
        die "retired resource survives for $tag" if grep { defined } @{$p->{weak}};
        for (0 .. $depth) {
            die "destruction count for $tag.$_" unless ($destroyed{"$tag.$_"} // 0) == 1;
        }
        splice @parked, $index, 1;
        for my $sibling (@parked) {
            die "sibling resource lost $sibling->{tag}" if grep { !defined } @{$sibling->{weak}};
        }
    }
    die "incomplete schedule" if @parked;
    die "insufficient coverage" unless $terminal{drop} && $terminal{fail} && $terminal{return};
    return 1;
}

for my $seed (@ARGV ? @ARGV : (11, 47, 503, 1609, 16127, 40849)) {
    my $ok = eval { exercise($seed) };
    ok($ok, "interleaved returns, failures, drops, frame values and resources, seed $seed") or diag "$@";
}
done_testing;
