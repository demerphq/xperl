#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;
our ($visible, $ambient) = ('root', 'ambient');
my $root_reference = \$visible;
sub create_owner {
    gen {
        my ($tag, $n) = @_;
        local $visible = $tag;
        my $original = \$visible;
        for my $i (1 .. $n) {
            my $command = yield [$original, $visible, $ambient, $i];
            die "stop $tag\n" if $command;
        }
        return [$original, $visible, $ambient, 0];
    };
}
sub exercise {
    my ($seed) = @_;
    my $rng = $seed;
    my $pick = sub {
        $rng = 48271 * ($rng % 44488) - 3399 * int($rng / 44488);
        $rng += 2147483647 if $rng <= 0;
        return $rng % $_[0];
    };
    my (@parked, %ends);
    my $serial = 0;
    for my $turn (1 .. 180) {
        my $stage = "seed $seed turn $turn";
        local $ambient = $stage;
        local $visible = "caller/$stage";
        my $caller = \$visible;
        if ($turn < 155 && (!@parked || (@parked < 18 && $pick->(3) == 0))) {
            my $tag = "item" . ++$serial;
            my $steps = 1 + $pick->(4);
            my $g = create_owner();
            my $v = $g->($tag, $steps);
            die "$stage: wrong initial binding" unless $v->[0] != $caller
                && $v->[1] eq $tag && $v->[2] eq $stage && $v->[3] == 1;
            push @parked, [$g, $tag, $steps, 1, $v->[0]];
        } elsif (@parked) {
            my $ix = $pick->(scalar @parked);
            my $p = $parked[$ix];
            my ($g, $tag, $steps, $i, $original) = @$p;
            my $action = $turn >= 155 ? 0 : $pick->(10);
            if (!$action) {
                $p->[0] = undef;
                undef $g;
                splice @parked, $ix, 1;
                ++$ends{drop};
            } elsif ($action == 1) {
                eval { scalar $g->('fail') };
                die "$stage: wrong failure" unless "$@" =~ /stop \Q$tag\E\n/;
                splice @parked, $ix, 1;
                ++$ends{fail};
            } else {
                my $v = $g->();
                my $expected = $i == $steps ? 0 : $i + 1;
                die "$stage: wrong resumed binding" unless $v->[0] == $original
                    && $v->[1] eq $tag && $v->[2] eq $stage && $v->[3] == $expected;
                if ($expected) {
                    $p->[3] = $expected;
                } else {
                    splice @parked, $ix, 1;
                    ++$ends{return};
                }
            }
        } else {
            last;
        }
        die "$stage: caller binding changed" unless \$visible == $caller && $visible eq "caller/$stage";
        for my $p (@parked) {
            die "$stage: changed a sibling" unless ${$p->[4]} eq $p->[1];
        }
    }
    die "unfinished schedule" if @parked;
    die "missing termination path" unless $ends{drop} && $ends{fail} && $ends{return};
    die "root binding replaced" unless \$visible == $root_reference && $visible eq 'root';
    return 1;
}
for my $seed (11, 47, 503, 1609, 16127, 40849) {
    my $ok = eval { exercise($seed) };
    ok($ok, "independent localized bindings and current callers, seed $seed") or diag "$@";
}
done_testing;
