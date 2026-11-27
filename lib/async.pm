package async;

use v5.40;
use feature ();
use builtin ();

our $VERSION = '0.01';

sub import {
    feature->import('async', 'signatures');
    builtin->import('run');
    require XPerl::Task;
}

1;

=head1 NAME

async - enable the experimental async task prototype

=head1 SYNOPSIS

    use async;
    no warnings 'experimental::builtin';

    async sub answer () {
        await XPerl::Task->delay(0.01);
        return 42;
    }

    print run(answer()), "\n";

=head1 DESCRIPTION

Enables C<async sub> and C<await>, and imports the built-in C<run> driver.
This is a prototype. See L<XPerl::Task> for scheduling and suspension limits.

=cut
