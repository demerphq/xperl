#!perl -w

BEGIN {
    if( $ENV{PERL_CORE} ) {
        chdir 't';
        @INC = ('../lib', 'lib');
    }
    else {
        unshift @INC, 't/lib';
    }
}

use strict;

use Test::More 'no_plan';

require Test::Builder;
my $tb = Test::Builder->new;


# Test that _try() has no effect on $@ and $! and is not effected by
# __DIE__
{
    local $SIG{__DIE__} = sub { fail("DIE handler called: @_") };
    local $@ = 42;
    local $! = 23;

    is $tb->_try(sub { 2 }), 2;
    is $tb->_try(sub { return '' }), '';

    is $tb->_try(sub { die; }), undef;

    is_deeply [$tb->_try(sub { die "Foo\n" })], [undef, "Foo\n"];

    is $@, 42;
    cmp_ok $!, '==', 23;
}

ok !eval {
    $tb->_try(sub { die "Died\n" }, die_on_fail => 1);
};
if (${^XPERL_VERSION}) {
    # The original text is one diagnostic in XPerl's rethrow graph.
    my $error = $@;
    require XPerl::DiagGroup unless $error->can('has_diagnostic');
    ok $error->has_diagnostic('ERROR_USER_TEXT', text => "Died\n");
}
else {
    is $@, "Died\n";
}
