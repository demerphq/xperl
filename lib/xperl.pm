package xperl;

use v5.40;

# Version declarations enable strictness without loading its import method.
use strict ();
use warnings;
no warnings 'experimental::builtin';

use feature ();
use builtin ();

our $VERSION = '0.01';

sub import {
    strict->import;
    warnings->import;
    warnings->unimport('experimental');

    feature->import(':all');
    feature->unimport(qw(
        apostrophe_as_package_separator bareword_filehandles
        indirect multidimensional smartmatch switch
    ));

    require generator;
    generator->import;
    builtin->import(':all');

    # Nested scopes inherit both the predicate aliases and this hint.
    # Repeated imports should not declare the same lexical subs again.
    unless ($^H{'xperl/predicates'}) {
        require dispatch::Predicates;
        builtin::export_lexically(map {
            $_ => dispatch::Predicates->can($_)
        } @dispatch::Predicates::EXPORT);
        $^H{'xperl/predicates'} = 1;
    }
}

1;

__END__

=head1 NAME

xperl - enable the XPerl language and its supporting functions

=head1 SYNOPSIS

    use xperl;

    multi sub fib(0) { 0 }
    multi sub fib(1) { 1 }
    multi sub fib($n if $n > 1) { fib($n - 1) + fib($n - 2) }

    say fib(10);

=head1 DESCRIPTION

C<use xperl> enables the language features and supporting functions provided
by the current XPerl interpreter. It enables L<strict> and L<warnings>, and
silences the C<experimental> warning categories.

The pragma enables all features in L<feature>, including classes and roles,
dispatch patterns, multi declarations, generators, and
signatures. The exceptions are the older syntax disabled by modern Perl
version bundles: C<apostrophe_as_package_separator>,
C<bareword_filehandles>, C<indirect>, C<multidimensional>, C<smartmatch>, and
C<switch>.

The pragma imports all L<builtin> functions and the standard pattern
predicates from L<dispatch::Predicates>. These imports are lexical and do not
add functions or methods to the caller's package. It also loads L<generator>
and its iterator protocol, so generator object methods are available.

The settings and imported names apply from the C<use> statement to the end
of the enclosing lexical scope. Individual settings can be changed after
the import with C<no feature>, C<no strict>, or C<use warnings>. Imported
lexical functions remain available until the enclosing scope ends.

This pragma follows the current interpreter's features and builtin set.
Use individual pragmas and explicit imports when a program needs a fixed
set of enabled features or names.

=head1 SEE ALSO

L<feature>, L<builtin>, L<dispatch::Predicates>, L<perldispatchon>,
L<perlmultitut>, L<perlgenerator>.

=cut
