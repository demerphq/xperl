package RNG::Provider;

use v5.24;
use strict;
use warnings;

our $VERSION = '0.02';

sub rand_bytes { die "RNG::Provider must implement rand_bytes\n" }
sub srand { die "RNG::Provider must implement srand\n" }

1;

=head1 NAME

RNG::Provider - abstract base class for C<${^RNG}> providers

=head1 DESCRIPTION

Subclasses of C<RNG::Provider> can be assigned to C<${^RNG}>.  They must
implement C<rand_bytes> and C<srand>.  Those base methods throw exceptions to
make an incomplete implementation fail at the call site.

XS providers may register a native U01 callback and owned state using
C<Perl_rng_fast_register>.  U01 means a uniform value in [0,1).
The fast path bypasses Perl method dispatch, including subclass overrides
of C<rand_bytes>.  Reblessing does not remove a native registration.
Pure-Perl providers use C<rand_bytes> and need no registration.
See L<perlrng>.

=cut
