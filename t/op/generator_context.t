#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use generator;
use feature 'try';
no warnings 'experimental::try';
use builtin 'refaddr';
no warnings 'experimental::builtin';

my $caught = gen {
    eval { yield 'ready'; die "inside eval\n" };
    yield "caught:$@";
    return 'finished';
};
is($caught->(), 'ready', 'eval scope suspends');
my $value;
my $ok = eval { $value = $caught->(); 1 };
ok($ok, 'resumed exception stays inside its eval');
like($value // '', qr/^caught:inside eval/, 'eval continues with its error');
is($caught->(), 'finished', 'generator continues after its handler') if $ok;

my $reference = bless {}, 'GeneratorContextError';
my ($inside, $inside_meta);
my $tried = gen {
    try { yield 'try'; die $reference }
    catch ($error, $exception) {
        $inside = $error;
        $inside_meta = $exception;
        yield 'caught';
    }
    return 'done';
};
is($tried->(), 'try', 'try scope suspends');
$ok = eval { $value = $tried->(); 1 };
ok($ok, 'resumed exception stays inside its catch');
is($value, 'caught', 'catch can suspend again') if $ok;
is($inside, $reference, 'catch retains the user reference');
is(ref($inside_meta), 'XPerl::Exception', 'catch receives the canonical exception');
is($tried->(), 'done', 'try generator finishes after its catch') if $ok;

my $nested = gen {
    eval {
        eval { yield 'nested'; die "inner\n" };
        yield "inner:$@";
        die "outer\n";
    };
    yield "outer:$@";
};
is($nested->(), 'nested', 'nested eval scopes suspend together');
$ok = eval { $value = $nested->(); 1 };
ok($ok, 'inner handler resumes without escaping');
like($value // '', qr/^inner:inner/, 'inner eval observes its own exception') if $ok;
if ($ok) {
    $ok = eval { $value = $nested->(); 1 };
    ok($ok, 'outer handler resumes without escaping');
    like($value // '', qr/^outer:outer/, 'outer eval observes its own exception');
}

my ($saved_meta, $outside_value, $outside_meta);
my $forwarded = gen {
    try { die $reference }
    catch ($error, $exception) {
        $saved_meta = $exception;
        yield 'forward';
        die $exception;
    }
};
is($forwarded->(), 'forward', 'canonical exception exists before suspension');
try { $forwarded->() }
catch ($error, $exception) {
    $outside_value = $error;
    $outside_meta = $exception;
}
is($outside_value, $reference, 'escaping failure retains its compatibility value');
is(ref($outside_meta), 'XPerl::Exception', 'escaping failure retains a canonical wrapper');
is(refaddr($outside_meta), refaddr($saved_meta), 'the boundary forwards the original exception object');

{
    package GeneratorContextTie;
    our @topics;
    sub TIESCALAR { bless {}, shift }
    sub FETCH { push @topics, $_; die "bad argument\n" }
}
{
    package GeneratorContextCleanup;
    sub DESTROY { $_[0]->() }
}
{
    local $_ = 'host';
    my @cleanup_topics;
    my $argument_error = gen {
        $_ = 'owner';
        eval {
            my $guard = bless sub {
                push @cleanup_topics, $_;
                $_ = 'cleanup';
            }, 'GeneratorContextCleanup';
            my $value = yield 'argument';
        };
        my $error = $@;
        my $topic = $_;
        $_ = 'handler';
        yield [$topic, $error];
        return $_;
    };
    is($argument_error->(), 'argument', 'resume argument test suspends');
    tie my $argument, 'GeneratorContextTie';
    my $result = $argument_error->($argument);
    is($result->[0], 'cleanup', 'argument FETCH failure catches after owner cleanup');
    like($result->[1], qr/^bad argument/, 'eval catches a resume argument FETCH failure');
    is(join(',', @GeneratorContextTie::topics), 'owner', 'argument FETCH runs under the owner topic');
    is(join(',', @cleanup_topics), 'owner', 'argument failure unwinds under the owner topic');
    is($_, 'host', 'argument FETCH failure preserves the caller topic');
    is($argument_error->(), 'handler', 'later resume retains the handler topic');

    my $topic_argument = gen {
        $_ = 'private topic';
        my $value = yield 'topic argument';
        yield $value;
    };
    is($topic_argument->(), 'topic argument', 'topic argument test suspends');
    is($topic_argument->($_), 'host', 'passing the caller topic retains its value');
    is($_, 'host', 'passing the caller topic preserves it');

    my $topic_arguments = gen {
        $_ = 'private list topic';
        my @values = yield 'list arguments';
        yield join ':', @values;
    };
    is($topic_arguments->(), 'list arguments', 'list argument test suspends');
    is($topic_arguments->($_, 'middle', $_), 'host:middle:host',
       'list arguments retain repeated caller topic values');
}

done_testing;
