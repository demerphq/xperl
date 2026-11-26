#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;

# Namespace replacement affects later symbol lookups, so keep each case in
# its own interpreter rather than relying on local *glob restoration.
sub run_case {
    my ($program, $args, $name) = @_;
    local $::Level = $::Level + 1;
    my $output = fresh_perl($program, {switches => ['-I../lib'], args => $args});
    my $status = $?;
    is($output, 'PASS', $name);
    is($status, 0, "$name exits cleanly");
}

my $signal_program = <<'PROGRAM';
use strict;
use warnings;
use generator;
our %ordinary;
my $kind = shift;
my $g = $kind eq 'hash' ? gen {
    local %ordinary = (value => 42);
    yield $ordinary{value};
    return $ordinary{value};
} : gen {
    my @values = map { yield $_; $_ } (42);
    return $values[0];
};
delete $main::{'SIG'};
my $replacement = sub () { 1234 };
$main::{'SIG'} = $replacement;
my $first = $g->();
die "wrong first result\n" unless $first == 42;
die "SIG entry expanded\n" unless ref $main::{'SIG'} eq 'CODE';
die "SIG coderef replaced\n" unless $main::{'SIG'} == $replacement;
my $done = $g->();
die "wrong final result\n" unless $done == 42;
die "SIG entry expanded on resume\n" unless ref $main::{'SIG'} eq 'CODE';
print 'PASS';
PROGRAM

for my $kind (qw(hash map)) {
    run_case($signal_program, [$kind], "$kind preserves a raw SIG stash entry");
}

run_case(<<'PROGRAM', [], 'preflight recognizes the retained separator local');
use strict;
use warnings;
use generator;
local $/ = 'outside';
my $g = gen {
    local $/ = '|';
    local $_ = 'owner';
    yield 'first';
    yield 'second';
    return $/;
};
my $first = $g->();
die "wrong first result\n" unless $first eq 'first';
delete $main::{'/'};
my $replacement = sub () { 1234 };
$main::{'/'} = $replacement;
my $second = $g->();
die "retained local rejected\n" unless $second eq 'second';
die "separator entry expanded\n" unless ref $main::{'/'} eq 'CODE';
die "separator coderef replaced\n" unless $main::{'/'} == $replacement;
my $done = $g->();
die "wrong final separator\n" unless $done eq '|';
die "caller separator changed\n" unless $/ eq 'outside';
print 'PASS';
PROGRAM

my $alias_program = <<'PROGRAM';
use strict;
use warnings;
use generator;
our $value;
{
    package RootValidationGuard;
    sub DESTROY { ++${$_[0][0]} }
}
sub read_parts {
    return [$/, scalar <DATA>];
}
sub make_owner {
    my ($kind, $cleaned) = @_;
    gen {
        my $guard = bless [$cleaned], 'RootValidationGuard';
        local $/ = '|';
        if ($kind eq 'scalar') {
            local $value = '!';
            yield 'ready';
            return read_parts();
        }
        else {
            for $value ('!') {
                yield 'ready';
                return read_parts();
            }
        }
    };
}
my ($kind, $root, $ending) = @ARGV;
local $/ = 'caller separator';
$value = 'caller value';
my $rs;
{ no strict 'refs'; $rs = \*{'main::/'} }
my $cleaned = 0;
if ($root eq 'first') {
    local *value = *$rs;
    my $outside = \$/;
    my $g = make_owner($kind, \$cleaned);
    my $ok = eval { scalar $g->(); 1 };
    die "first yield admitted separator alias\n" if $ok;
    die "wrong first-yield diagnostic\n" unless $@ =~ /unsupported localization/;
    undef $g;
    die "caller separator replaced\n" unless \$/ == $outside;
    die "caller separator changed\n" unless $/ eq 'caller separator';
}
else {
    my $g = make_owner($kind, \$cleaned);
    my $first = $g->();
    die "wrong first result\n" unless $first eq 'ready';
    if ($root ne 'current') {
        delete $main::{'/'};
        if ($root eq 'retained') { $main::{'/'} = sub () { 1234 } }
        else { no strict 'refs'; $rs = \*{'main::/'} }
    }
    {
        local *value = *$rs;
        my ($outside, $before) = (\$/, $/);
        my ($alias, $alias_value) = (\$value, $value);
        my $ok = eval { scalar $g->(); 1 };
        die "resume admitted separator overlap\n" if $ok;
        die "wrong overlap diagnostic\n" unless $@ =~ /generator continuation is not available/;
        die "rejected resume failed the owner\n" if $g->failed;
        undef $g if $ending eq 'abandon';
        die "caller separator replaced\n" unless \$/ == $outside;
        die "caller separator changed\n" unless $/ eq $before;
        die "alias scalar replaced\n" unless \$value == $alias;
        die "alias scalar changed\n" unless defined $alias_value
            ? defined $value && $value eq $alias_value : !defined $value;
    }
    if ($ending eq 'retry') {
        my $done = $g->();
        die "separator and readline disagree\n" unless join('/', @$done) eq '|/A|';
    }
    undef $g;
}
die "wrong cleanup count\n" unless $cleaned == 1;
print 'PASS';
__DATA__
A|B!
PROGRAM

for my $kind (qw(scalar foreach)) {
    run_case($alias_program, [$kind, 'first'], "$kind rejects an initial separator alias");
    for my $root (qw(current retained replacement)) {
        for my $ending (qw(retry abandon)) {
            run_case($alias_program, [$kind, $root, $ending],
                     "$kind/$root/$ending preserves the caller separator");
        }
    }
}

done_testing;
