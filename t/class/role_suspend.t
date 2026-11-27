#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use feature 'class';
use async;
no warnings qw(experimental::class experimental::builtin);

role WaitingRole {
    field $value :param;
    method read_after_wait($depth) {
        return $self->read_after_wait($depth - 1) if $depth;
        await XPerl::Task->delay(0);
        return $value;
    }
}
class WaitingBase { field $padding = 999 }
class WaitingLeft :implements(WaitingRole) {}
class WaitingRight :isa(WaitingBase) :implements(WaitingRole) {}

async sub read_role($object, $depth) {
    return $object->read_after_wait($depth);
}
async sub interleave_roles() {
    my $left = read_role(WaitingLeft->new(value => 10), 3);
    my $right = read_role(WaitingRight->new(value => 20), 2);
    return [await $right, await $left];
}

is(run(read_role(WaitingLeft->new(value => 19), 1)), 19,
   'recursive ordinary role methods can await');
ok(eq_array(run(interleave_roles()), [20, 10]),
   'suspended role methods retain their consumer and field offset');

role WaitingFieldlessRole {
    method wait_for_self($depth) {
        return $self->wait_for_self($depth - 1) if $depth;
        await XPerl::Task->delay(0);
        return $self;
    }
}
class WaitingFieldless :implements(WaitingFieldlessRole) {}
async sub read_fieldless($object) { return $object->wait_for_self(2) }
my $object = WaitingFieldless->new;
is(run(read_fieldless($object)), $object,
   'fieldless role methods retain the composing class through recursion');

SKIP: {
    skip 'requires ithreads', 1 unless $Config::Config{useithreads};
    skip 'requires threads extension', 1 unless eval { require threads; 1 };
    my $thread = threads->create(sub {
        return run(read_role(WaitingRight->new(value => 42), 2));
    });
    is($thread->join, 42, 'a cold child interpreter can await in a role method');
}

done_testing();
