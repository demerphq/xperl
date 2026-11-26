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
# Tied element restoration can run Perl code. It must finish before yield,
# rather than leave an unsafe restore for a suspended owner's cleanup.
{
    local $_ = 'cleanup caller';
    our @tied;
    tie $tied[0], 'GeneratorCleanupTie';
    my ($caught, $cleaned) = (0, 0);
    my $g = gen {
        $_ = 'cleanup owner';
        my $guard = bless sub { ++$cleaned }, 'GeneratorCleanupGuard';
        {
            local $tied[0] = 'inside';
            eval { yield 'blocked' };
            $caught = $@;
            is($tied[0], 'inside', 'caught rejection retains the tied local');
        }
        yield 'safe';
    };
    is($g->(), 'safe', 'generator yields after the tied local ends');
    like($caught, qr/unsupported localization/, 'tied local rejects suspension');
    is($tied[0], 'outside', 'scope exit restores the tied element');
    is($cleaned, 0, 'rejection does not destroy the generator scope');
    abandon($g);
    is($cleaned, 1, 'abandonment destroys the surviving lexical guard once');
    is($_, 'cleanup caller', 'abandonment preserves the caller topic');
    untie $tied[0];
}

{
    our @fatal_tied;
    tie $fatal_tied[0], 'GeneratorCleanupTie';
    my $g = gen {
        local $fatal_tied[0] = 'inside';
        yield 'blocked';
    };
    my $ok = eval { scalar $g->(); 1 };
    ok(!$ok, 'uncaught rejection prevents parking a tied element');
    like($@, qr/unsupported localization/, 'tied element rejection reaches the caller');
    is($fatal_tied[0], 'outside', 'failed execution restores the tied element');
    untie $fatal_tied[0];
}

done_testing;
