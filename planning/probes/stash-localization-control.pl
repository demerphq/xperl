#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use feature "signatures";

our ($value, %ordinary);

# Ordinary localization control: no generators execute here.
# This currently reproduces a separate native symbol-localization failure.
for my $kind (qw(hash map)) {
    local $main::{'SIG'};
    delete $main::{'SIG'};
    my $replacement = sub () { 1234 };
    $main::{'SIG'} = $replacement;
    my $g = $kind eq 'hash' ? sub {
        local %ordinary = (value => 42);
        scalar $ordinary{value};
        return $ordinary{value};
    } : sub {
        my @values = map { scalar $_; $_ } (42);
        return $values[0];
    };
    is(scalar $g->(), 42, "$kind ordinary call returns with a raw SIG entry");
    is(ref $main::{'SIG'}, 'CODE', "$kind read leaves the SIG entry unexpanded");
    ok(ref $main::{'SIG'} eq 'CODE' && $main::{'SIG'} == $replacement,
       "$kind preserves the replacement coderef identity");
    is(scalar $g->(), 42, "$kind second ordinary call returns");
}

done_testing;
