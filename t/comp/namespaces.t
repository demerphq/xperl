#!./perl

use strict;
use warnings;

print "1..8\n";

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

my $alias = eval q{
    use feature 'namespaces';
    use Carp as C;
    C::croak('alias works');
};
print $@ =~ /alias works/ ? "ok 7 - package alias\n" : "not ok 7 - package alias\n";

my $duplicate = eval q{
    use feature 'namespaces';
    use Carp as C;
    use Carp as C;
};
print $@ =~ /Duplicate package alias/ ? "ok 8 - duplicate alias\n" : "not ok 8 - duplicate alias\n";
