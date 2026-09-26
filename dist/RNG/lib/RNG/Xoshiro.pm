package RNG::Xoshiro;

use v5.24;
use strict;
use warnings;
use RNG ();
use RNG::Provider ();
use RNG::Seed;

our $VERSION = '0.02';
our @ISA = 'RNG::Provider';

RNG::_load_xs();

sub rand_U01_callback {
    my ($self) = @_;
    return sub { $self->rand_U01 };
}

sub srand { RNG::_provider_srand($_[0], '_srand', @_[1 .. $#_]) }

1;

=head1 NAME

RNG::Xoshiro - a fast xoshiro256** pseudorandom number generator

=head1 SYNOPSIS

    use RNG::Xoshiro;

    my $rng = RNG::Xoshiro->new(42);
    my $number = $rng->rand(10);

    {
        local ${^RNG} = $rng;
        print rand(10), "\n";
    }

=head1 DESCRIPTION

This module implements the xoshiro256** 64-bit pseudorandom number generator.
It has a 256-bit state and is intended for fast simulation, testing, and
other non-cryptographic uses where a high-quality general-purpose generator
is useful.

The XS implementation owns native state attached to a blessed scalar
reference.  It registers its callback with core so C<rand> can call the
generator directly without Perl method dispatch or a temporary byte buffer.
The C<rand_bytes> method provides the byte interface.

This generator is not suitable for cryptography, security tokens, passwords,
or any other security-sensitive use.

=head1 METHODS

See L<RNG> for the provider interface used by C<${^RNG}>.

=head2 new( SEED )

Create a generator initialized from SEED. Defined seeds are stringified as
UTF-8. If SEED is omitted, it defaults to zero.

=head2 rand( [LIMIT] )

Return a pseudorandom floating-point value between zero and one, or between
zero and LIMIT when LIMIT is supplied.  A LIMIT of zero is treated as one.

=head2 rand_U01

Advance the generator and return a pseudorandom U01 value.  U01 means a
uniform floating-point value in the half-open interval [0,1).

=head2 rand_U01_callback

Return a callback which calls C<rand_U01> on this generator.

=head2 state

Return a fresh byte-string snapshot of the complete native generator state.
Drawing more values does not change the returned string.  The snapshot is
opaque and specific to this provider and build.

=head2 set_state( BYTES )

Restore a snapshot returned by C<state>.  The argument must be a byte string
of the expected length.  Restoration does not change the argument.  The
scalar referent is read-only and does not contain the generator state.

=head2 rand_bytes( LENGTH )

Advance the generator and return exactly LENGTH random bytes.  Bytes are
assembled in big-endian order.  LENGTH may be zero.

=head2 srand( [SEED] )

Reset the generator using SEED. An omitted or undefined seed obtains fresh
seed material and returns a replayable C<RNG::Seed>.  An explicit true seed
is returned unchanged.  A false seed string is returned as a true
C<RNG::Seed> object which stringifies to that seed and uses the same string
expansion when replayed.

=head1 SEE ALSO

L<RNG> and L<perlfunc/rand EXPR>.

=cut
