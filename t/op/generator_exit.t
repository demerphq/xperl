#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;

watchdog(30);
my $have_list_util = eval { require List::Util; 1 };
my @status_switches = $^O eq 'VMS' ? ('-Mvmsish=hushed') : ();
my $program = <<'PROGRAM';
use strict;
use warnings;
use generator;
use builtin 'weaken';
no warnings 'experimental::builtin';

my ($mode, $status) = @ARGV;
our (@weak, @released, @keep);
{
    package ExitArgument;
    sub DESTROY { push @main::released, $_[0][0] }
}
{
    package ExitGuard;
    sub DESTROY { $_[0]->() }
}
sub argument {
    my $value = bless [$_[0]], 'ExitArgument';
    push @weak, $value;
    weaken($weak[-1]);
    return $value;
}

$_ = 'root';
END {
    print 'END topic=', $_ // '<undef>',
          ' alive=', scalar(grep { defined } @weak),
          ' released=', join(',', sort @released), "\n";
}
if ($mode eq 'outside_hook') {
    local $SIG{__EXCEPT__} = sub { exit $status };
    die "invoke hook without a generator\n";
}
sub run_case {
    local $_ = 'caller';
    my $g = gen {
        $_ = 'body';
        if ($mode eq 'body') {
            exit $status;
        }
        if ($mode eq 'eval') {
            eval { exit $status };
            die "eval caught exit";
        }
        if ($mode eq 'sort') {
            my @values = sort { exit $status } qw(c b);
        }
        if ($mode eq 'xs') {
            require List::Util;
            my $value = List::Util::first(sub {
                die "wrong callback topic\n" unless $_ == 17;
                exit $status;
            }, 17);
        }
        if ($mode eq 'exception_hook') {
            local $SIG{__EXCEPT__} = sub { exit $status };
            die "invoke exception hook\n";
        }
        if ($mode eq 'nested') {
            my $child = gen { $_ = 'child'; exit $status };
            push @keep, $child;
            $child->(argument('child'));
        }
        if ($mode eq 'nested_abandon') {
            my $child = gen {
                $_ = 'child';
                my $guard = bless sub { exit $status }, 'ExitGuard';
                yield 1;
            };
            $child->(argument('child'));
            undef $child;
        }
        if ($mode eq 'abandon') {
            my $guard = bless sub { exit $status }, 'ExitGuard';
            yield 1;
        }
        if ($mode eq 'resume') {
            yield 1;
            exit $status;
        }
        die "continued in generator";
    };
    push @keep, $g unless $mode =~ /abandon/;
    $g->(argument('body'));
    if ($mode eq 'abandon') {
        undef $g;
    }
    elsif ($mode eq 'resume') {
        $g->(argument('resume'));
    }
    die "continued after exit";
}
run_case();
PROGRAM

my $program_file = tempfile();
open my $source, '>', $program_file or die "open $program_file: $!";
print {$source} $program;
close $source or die "close $program_file: $!";

my %exit_status;
for my $status (0, 1, 23, 173, 255) {
    runperl(prog => "exit $status", switches => \@status_switches, stderr => 1);
    $exit_status{$status} = $?;
}

for my $mode (qw(body resume eval sort xs exception_hook outside_hook nested abandon nested_abandon)) {
    SKIP: {
        skip 'List::Util is unavailable', 2 if $mode eq 'xs' && !$have_list_util;
        my $output = runperl(progfile => $program_file, switches => \@status_switches,
                             args => [$mode, 23], stderr => 1);
        my $status = $?;
        my $labels = $mode eq 'outside_hook' ? ''
                   : $mode =~ /nested/ ? 'body,child'
                   : $mode eq 'resume' ? 'body,resume' : 'body';
        is($status, $exit_status{23}, "$mode preserves process exit status");
        is($output, "END topic=root alive=0 released=$labels\n",
           "$mode releases execution resources before END");
    }
}
for my $status (0, 1, 173, 255) {
    my $output = runperl(progfile => $program_file, switches => \@status_switches,
                         args => ['nested', $status], stderr => 1);
    is($?, $exit_status{$status}, "nested exit preserves status $status");
    is($output, "END topic=root alive=0 released=body,child\n",
       'nested exit preserves the caller and releases arguments');
}

done_testing;
