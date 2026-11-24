#!perl

use strict;
use warnings;

require "../../t/test.pl";

use XS::APItest;

# clone_with_stack creates a clone of the perl interpreter including
# the stack, then destroys the original interpreter and runs the
# remaining code using the new one.
# This is like doing a pseudo-fork and exiting the parent.

use Config;
if (not $Config{'useithreads'}) {
    skip_all("clone_with_stack requires threads");
}

plan(11);

SKIP: {
    skip('requires emulated fork', 1) unless $Config{'d_pseudofork'};
    fresh_perl_is( <<'----', <<'====', undef, 'recover from rejecting emulated fork in a generator' );
use warnings;
use generator;
$| = 1;
my $g = gen {
    my $ok = eval { fork(); 1 };
    die "forked an active owner\n" if $ok;
    die "unexpected fork error: $@" unless $@ =~ /generator continuation is not available/;
    yield "caught\n";
};
print $g->();
undef $g;
my $pid = fork();
die "ordinary fork failed: $!" unless defined $pid;
exit 0 unless $pid;
waitpid $pid, 0;
die "child failed\n" if $?;
print "forked\n";
----
caught
forked
====
}

fresh_perl_is( <<'----', <<'====', undef, 'reject a copied stack with a native generator owner' );
use warnings;
use XS::APItest;
use generator;
$| = 1;
my $g = gen {
    my $ok = eval { clone_with_stack(); 1 };
    die "cloned an active owner\n" if $ok;
    die "unexpected clone error: $@" unless $@ =~ /generator continuation is not available/;
    yield "caught\n";
};
print $g->();
my $parked = gen { yield 1 };
$parked->();
clone_with_stack();
print "outside clone\n";
----
caught
outside clone
====

fresh_perl_is( <<'----', <<'====', undef, 'clone deferred generator cleanup warnings' );
use warnings;
use XS::APItest;
use generator;
{
    package CleanupTie;
    our $fail;
    sub TIESCALAR { bless ['outside'], shift }
    sub FETCH { $_[0][0] }
    sub STORE {
        if ($fail && $_[1] eq 'outside') {
            $fail = 0;
            die "cleanup failed\n";
        }
        $_[0][0] = $_[1];
    }
}
our @value;
# Element locals exercise throwing restoration in the scalar prototype too.
tie $value[0], 'CleanupTie';
{
    my $g = gen {
        local $value[0] = 'inside';
        yield 1;
    };
    $g->();
    local $SIG{__WARN__} = sub { print "cleanup warning\n" };
    $CleanupTie::fail = 1;
    undef $g;
    clone_with_stack();
    print "cloned\n";
}
print "done\n";
----
cleanup warning
cloned
cleanup warning
done
====

fresh_perl_is( <<'----', <<'====', undef, "minimal clone_with_stack" );
use XS::APItest;
clone_with_stack();
print "ok\n";
----
ok
====

fresh_perl_is( <<'----', <<'====', undef, "inside a subroutine" );
use XS::APItest;
sub f {
    clone_with_stack();
}
f();
print "ok\n";
----
ok
====

{
    local our $TODO = "clone_with_stack inside a begin block";
    fresh_perl_is( <<'----', <<'====', undef, "inside a BEGIN block" );
use XS::APItest;
BEGIN {
    clone_with_stack();
}
print "ok\n";
----
ok
====

}

{
    fresh_perl_is( <<'----', <<'====', undef, "clone stack" );
use XS::APItest;
sub f {
    clone_with_stack();
    0..4;
}
print 'X-', 'Y-', join(':', f()), "-Z\n";
----
X-Y-0:1:2:3:4-Z
====

}

{
    fresh_perl_is( <<'----', <<'====', undef, "with a lexical sub" );
use XS::APItest;
use experimental lexical_subs=>;
my sub f { print "42\n" }
clone_with_stack();
f();
----
42
====

}

{
    fresh_perl_is( <<'----', <<'====', undef, "with localised stuff" );
use XS::APItest;
$s = "outer";
$a[0] = "anterior";
$h{k} = "hale";
{
    local $s = "inner";
    local $a[0] = 'posterior';
    local $h{k} = "halt";
    clone_with_stack();
}
print "scl: $s\n";
print "ary: $a[0]\n";
print "hsh: $h{k}\n";
----
scl: outer
ary: anterior
hsh: hale
====

}

{
    fresh_perl_is( <<'----', <<'====', undef, "inside a loop inside a fn" );
use XS::APItest;
my $a = 'aa';
sub f {
    my $b = 'bb';
    my @c;
    my $d = 'dd';
    for my $d (0..4) {
	clone_with_stack() if $d == 2;
	push @c, $d;
    }
    return @c, $d;
}
print "X-$a-", join(':', f()), "-Z\n";
----
X-aa-0:1:2:3:4:dd-Z
====

}

{
    fresh_perl_is( <<'----', <<'====', undef, "inside fn inside a loop inside a fn" );
use XS::APItest;
my $a = 'aa';

sub g {
    my $e = 'ee';
    my $f = 'ff';
    clone_with_stack();
}

sub f {
    my $b = 'bb';
    my @c;
    my $d = 'dd';
    for my $d (0..4) {
	g() if $d == 2;
	push @c, $d;
    }
    return @c, $d;
}
print "X-$a-", join(':', f()), "-Z\n";
----
X-aa-0:1:2:3:4:dd-Z
====

}
