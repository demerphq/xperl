#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;

sub abandon { undef $_[0] }

{
    package GeneratorCleanupGuard;
    sub DESTROY { $_[0]->() }
}

my @seen;
{
    local $_ = 'caller';
    my $g = gen {
        $_ = 'owner';
        my $guard = bless sub {
            push @seen, $_;
            $_ = 'cleanup';
        }, 'GeneratorCleanupGuard';
        yield 1;
    };
    is($g->(), 1, 'generator suspends with live cleanup');
    abandon($g);
    is(join(',', @seen), 'owner', 'abandoned scope cleanup sees its own topic');
    is($_, 'caller', 'abandoned scope cleanup preserves the caller topic');
}

sub abandon_with_arguments {
    my $caller_arguments = \@_;
    my $owner_arguments;
    my $g = gen {
        $owner_arguments = \@_;
        yield $_[0];
    };
    is($g->('owner argument'), 'owner argument', 'generator has its own arguments');
    abandon($g);
    is(\@_, $caller_arguments, 'abandonment preserves the caller argument array identity');
    is(join(',', @_), 'caller argument', 'abandonment restores the caller argument array');
    is(join(',', @$owner_arguments), 'owner argument', 'escaped argument array keeps its contents');
}
abandon_with_arguments('caller argument');

{
    local $_ = 'temporary caller';
    my @topics;
    my $g = gen {
        $_ = 'temporary owner';
        my @pending = (
            bless(sub {
                push @topics, $_;
                my $text = join '', map { "temporary $_" } 1 .. 4096;
                die "missing temporary data" unless length $text;
            }, 'GeneratorCleanupGuard'),
            scalar(yield 'pending list')
        );
    };
    is($g->(), 'pending list', 'temporary survives yield in an unfinished list');
    abandon($g);
    is(join(',', @topics), 'temporary owner', 'temporary is destroyed once under its owner');
    is($_, 'temporary caller', 'temporary cleanup preserves the caller topic');
}

# Cleanup may abandon a second execution while the first is unwinding.
{
    local $_ = 'outside';
    my @order;
    my $inner = gen {
        $_ = 'inner';
        my $guard = bless sub {
            push @order, $_;
            $_ = 'inner cleanup';
        }, 'GeneratorCleanupGuard';
        yield 1;
    };
    my $outer = gen {
        $_ = 'outer';
        my $guard = bless sub {
            push @order, $_;
            undef $inner;
            push @order, $_;
        }, 'GeneratorCleanupGuard';
        yield 2;
    };
    is($inner->(), 1, 'inner execution suspends');
    is($outer->(), 2, 'outer execution suspends');
    undef $outer;
    is(join(',', @order), 'outer,inner,outer',
       'nested abandonment restores each cleanup environment');
    is($_, 'outside', 'nested abandonment preserves the caller topic');
}

{
    package GeneratorCleanupTie;
    our ($fail, $failure);
    sub TIESCALAR { bless {value => 'outside'}, shift }
    sub FETCH { $_[0]{value} }
    sub STORE {
        my ($self, $value) = @_;
        if ($fail && $value eq 'outside') {
            --$fail;
            die($failure // "cleanup store failed\n");
        }
        $self->{value} = $value;
    }
}
{
    local $_ = 'cleanup caller';
    our $tied;
    tie $tied, 'GeneratorCleanupTie';
    my ($continued, $cleaned) = (0, 0);
    my $g = gen {
        $_ = 'cleanup owner';
        my $guard = bless sub { ++$cleaned }, 'GeneratorCleanupGuard';
        eval {
            local $tied = 'inside';
            yield 'tied local';
        };
        ++$continued;
    };
    is($g->(), 'tied local', 'generator suspends with a tied local');
    eval { die "caller error\n" };
    my $caller_error = $@;
    my $caller_exception = ${^ERROR_OBJ};
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, [$_, "$_[0]"] };
    $GeneratorCleanupTie::fail = 1;
    abandon($g);
    is($continued, 0, 'cleanup error does not enter the abandoned handler');
    is($cleaned, 1, 'cleanup continues after a tied restoration error');
    is($_, 'cleanup caller', 'throwing cleanup restores the caller topic');
    is($@, $caller_error, 'throwing cleanup preserves the caller error');
    is(${^ERROR_OBJ}, $caller_exception, 'throwing cleanup preserves the canonical caller exception');
    is(scalar @warnings, 1, 'throwing cleanup reports a warning');
    like($warnings[0][1] // '', qr/cleanup store failed/, 'warning explains the cleanup failure');
    is($warnings[0][0], 'cleanup caller', 'warning runs after restoring the caller');
    untie $tied;
}

{
    our ($first_tied, $second_tied);
    tie $first_tied, 'GeneratorCleanupTie';
    tie $second_tied, 'GeneratorCleanupTie';
    eval { die "repeated cleanup failure\n" };
    local $GeneratorCleanupTie::failure = ${^ERROR_OBJ};
    my $g = gen {
        eval {
            local $first_tied = 'first';
            eval {
                local $second_tied = 'second';
                yield 'two tied locals';
            };
        };
    };
    is($g->(), 'two tied locals', 'nested tied locals suspend');
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, "$_[0]" };
    $GeneratorCleanupTie::fail = 2;
    abandon($g);
    is(scalar @warnings, 2, 'each throwing restore reports its error');
    like($warnings[0] // '', qr/repeated cleanup failure/, 'first restore failure is reported');
    like($warnings[1] // '', qr/repeated cleanup failure/, 'rethrowing the same exception is safe');
    my $original_messages = () = "$GeneratorCleanupTie::failure"
        =~ /^repeated cleanup failure$/mg;
    is($original_messages, 1, 'reporting does not duplicate the original diagnostic');
    untie $first_tied;
    untie $second_tied;
}

{
    our $fatal_tied;
    tie $fatal_tied, 'GeneratorCleanupTie';
    my $g = gen {
        local $fatal_tied = 'inside';
        yield 'fatal warning';
    };
    is($g->(), 'fatal warning', 'fatal cleanup warning test suspends');
    local $SIG{__WARN__} = sub { die "warning hook failed\n" };
    $GeneratorCleanupTie::fail = 1;
    my $ok = eval { undef $g; 1 };
    ok(!$ok, 'a throwing warning hook reaches the caller');
    like($@, qr/warning hook failed/, 'caller receives the warning hook exception');
    untie $fatal_tied;
}

done_testing;
