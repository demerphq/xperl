#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
    skip_all('requires ithreads') unless $Config::Config{useithreads};
    skip_all_without_dynamic_extension('threads');
    skip_all_without_dynamic_extension('Time::HiRes');
}

use strict;
use warnings;
use threads ();
use async;
use feature 'multisub';
no warnings 'experimental::multisub';
no warnings 'experimental::builtin';

async sub answer ($value) {
    await XPerl::Task->delay(0);
    return $value + 1;
}

async sub create_thread () {
    my $child = threads->create(sub { return run(answer(21)) });
    my $value = $child->join;
    await XPerl::Task->delay(0);
    return $value;
}

is(run(create_thread()), 22, 'child interpreter starts with an independent driver');
is(run(answer(41)), 42, 'parent interpreter remains usable after cloning');

async multi sub classify('double', $value) {
    await XPerl::Task->delay(0);
    return $value * 2;
}
async multi sub classify('other') { return 42 }
my $child = threads->create(sub { run(classify('double', 21)) });
is($child->join, 42, 'child interpreter retains async multi bodies');
is(run(classify('other')), 42, 'parent async multi remains usable after cloning');

done_testing();
