use v5.40;
use generator;

{
    package Observer;
    sub DESTROY { $_[0][0]->() }
}
our ($left, $right) = ('host left', 'host right');

sub park_pair ($events) {
    my $g = gen {
        local $left = 'owner left';
        local $right = 'owner right';
        my $guard = bless [sub { push @$events, "$left / $right" }], 'Observer';
        yield 'parked';
    };
    my $ready = $g->();
    return $g;
}

{
    my @seen;
    my $g = park_pair(\@seen);
    local *left = *right;
    undef $g;
    say "merge, current prototype DESTROY: @seen; caller: $left / $right";
}
{
    local *left = *right;
    my @seen;
    my $g;
    {
        local *left;
        $left = 'temporary host';
        $g = park_pair(\@seen);
    }
    # The incompatible merge occurred on scope exit.
    undef $g;
    say "implicit merge, current prototype DESTROY: @seen; caller: $left / $right";
}
{
    my @seen;
    my $g = park_pair(\@seen);
    local $_ = 'host topic';
    local *left = *main::_;
    undef $g;
    say "special retarget, current prototype DESTROY: @seen; caller topic: $_";
}

{
    our $untracked;
    my @seen;
    my $g = gen {
        local $left = 'private';
        my $guard = bless [sub { push @seen, "$left / $untracked" }], 'Observer';
        yield 'parked';
    };
    my $ready = $g->();
    local *untracked = *left;
    undef $g;
    say "new untracked alias, DESTROY: @seen; caller: $left / $untracked";
}

{
    package Lookup;
    our $slot = 'original';
    sub compiled { $slot }
    sub lookup ($symbol) {
        no strict 'refs';
        return ${$symbol};
    }
    sub assign ($symbol, $value) {
        no strict 'refs';
        ${$symbol} = $value;
    }
}
{
    my $slot_name = join '::', qw(Lookup slot);
    my @seen;
    my $g = gen {
        local $Lookup::slot = 'owner';
        my $guard = bless [sub {
            push @seen, Lookup::compiled(), Lookup::lookup($slot_name);
        }], 'Observer';
        yield 'parked';
    };
    my $ready = $g->();
    delete $Lookup::{slot};
    Lookup::assign($slot_name, 'replacement');
    undef $g;
    say "deleted stash entry, DESTROY static/dynamic: @seen; caller static/dynamic: ",
        Lookup::compiled(), ' / ', Lookup::lookup($slot_name);
}

{
    our ($original, @original);
    for my $pin (0, 1) {
        my @seen;
        {
            local *original;
            $original = bless [sub { push @seen, 'scalar' }], 'Observer';
            @original = (bless [sub { push @seen, 'array' }], 'Observer');
            *Keep::gp = *original if $pin;
        }
        my $after_return = join ',', sort @seen;
        undef *Keep::gp if $pin;
        say "pin=$pin; freed at caller scope exit=[$after_return]; after unpin=[",
            join(',', sort @seen), ']';
    }
}
