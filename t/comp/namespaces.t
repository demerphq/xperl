#!./perl

use strict;
use warnings;

print "1..6\n";

my $result = eval q{
    use feature 'namespaces';
    namespace Alpha;
    my $one = __NAMESPACE__;
    package Beta;
    my $two = __PACKAGE__;
    namespace Gamma;
    my $three = __NAMESPACE__;
    namespace :::Root;
    my $four = __NAMESPACE__;
    [ $one, $two, $three, $four ];
};
print !$@ && $result->[0] eq 'Alpha' ? "ok 1 - namespace\n" : "not ok 1 - namespace\n";
print !$@ && $result->[1] eq 'Alpha::Beta' ? "ok 2 - package\n" : "not ok 2 - package\n";
print !$@ && $result->[2] eq 'Alpha::Gamma' ? "ok 3 - relative namespace\n" : "not ok 3 - relative namespace\n";
print !$@ && $result->[3] eq 'Root' ? "ok 4 - absolute namespace\n" : "not ok 4 - absolute namespace\n";

my $off = eval q{
    package NamespaceFeatureOff;
    __PACKAGE__;
};
print !$@ && $off eq 'NamespaceFeatureOff' ? "ok 5 - feature off\n" : "not ok 5 - feature off\n";

my $bad = eval q{
    use feature 'namespaces';
    namespace A:::B:::C;
};
print $@ =~ /Malformed namespace separator/ ? "ok 6 - malformed separator\n" : "not ok 6 - malformed separator\n";
