package generator;

use v5.40;

sub import {
    require feature;
    feature->import('generator', 'signatures');

    require builtin;
    builtin->import(qw(
        generator_exhausted
        generator_completed
        generator_failed
        generator_running
    ));
}

1;

=head1 NAME

generator - enable generator syntax and import generator predicates

=head1 SYNOPSIS

    use generator;

    my $g = generator_create {
        generator_yield 1;
    };

    generator_exhausted($g);

=head1 DESCRIPTION

This pragma enables the experimental C<generator> and C<signatures> features
and lexically imports the generator predicate builtins. It is equivalent to
the following declarations:

    use feature qw(generator signatures);
    use builtin qw(
        generator_running
        generator_completed
        generator_failed
        generator_exhausted
    );

The declarations apply from the point of the C<use generator> statement to
the end of the current lexical scope.  The pragma is the normal entry point
for code that uses generators, especially parameterized generators.  Code
that only needs the two generator keywords can use C<use feature 'generator'>
instead, and code that needs only the predicates can import them with
C<use builtin>.

The C<generator_create> and C<generator_yield> constructs are feature syntax.
The predicates C<generator_running>, C<generator_completed>,
C<generator_failed>, and C<generator_exhausted> are ordinary builtins and may
also be imported directly with C<use builtin>.

See L<perlgenerator> for the complete guide.

=cut
