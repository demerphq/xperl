#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

plan(33);

require Scalar::Util;

fresh_perl_is(q{
    use feature qw(case_match say);
    our $calls = 0;
    package Key {
        use overload '""' => sub { ++$main::calls; 'x' };
    }
    my $key = bless {}, 'Key';
    case ({x=>1,y=>2}) with ($key) {
        match ({$key=>1}) { say 'wrong exactness' }
        match (_) { say "miss,$calls" }
    }
}, 'miss,1', {}, 'runtime hash keys are stringified once per key requirement');

fresh_perl_is(q{
    use feature qw(case_match say);
    my @closures;
    for my $throws (0, 1) {
        eval {
            case ([42, 43]) {
                match ([$x, @tail] if do {
                    push @closures, sub { ($x, @tail) };
                    die "guard error\n" if $throws;
                    0;
                }) { die 'wrong clause' }
                match (_) { }
            }
        };
        die $@ if $@ && $@ ne "guard error\n";
    }
    say join ',', $_->() for @closures;
}, "42,43\n42,43", {},
    'guard rejection and exceptions preserve escaped lexical bindings');

fresh_perl_is(q{
    use feature qw(case_match say);
    for my $shape ('{a=>1,a=>1}', '{1=>1,"1"=>1}',
                   '[{a=>1,a=>1}]', 'Point {a=>1,a=>1}') {
        eval 'case ({a=>1,b=>2}) { match (' . $shape . ') { 1 } }';
        say $@ =~ /duplicate key .* in a case hash pattern/
            ? 'rejected' : 'wrong result';
    }
}, "rejected\nrejected\nrejected\nrejected", {},
    'statically duplicate keys are rejected in plain and object hash shapes');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    my ($a, $b) = ('x', 'x');
    for my $subject ({x=>1,y=>1}, {x=>1}, {x=>2}) {
        case ($subject) with ($a,$b) {
            match ({$a=>1,$b=>1}) { say 'hit' }
            match (_) { say 'miss' }
        }
    }
}, "miss\nhit\nmiss", {},
    'runtime key collisions preserve exactness without duplicate-key errors');

fresh_perl_is(q{
    use feature qw(case_match say);
    my $key = 'x';
    case ({x=>1,y=>2}) {
        match ({x=>1,^$key=>2,...}) { say 'wrong value constraint' }
        match ({x=>1,^$key=>1}) { say 'wrong exactness' }
        match ({x=>1,^$key=>1,...}) { say 'open hit' }
    }
}, 'open hit', {},
    'colliding literal and caret-pinned keys retain all value constraints');

fresh_perl_is(q{
    use feature qw(case_match say);
    my $calls = 0;
    sub key { ++$calls; 'x' }
    case ({x=>1,y=>2}) {
        match ({key()=>1,key()=>1}) { say 'wrong exactness' }
        match (_) { say "miss,$calls" }
    }
}, 'miss,2', {}, 'runtime key-producing calls are evaluated once per key');

fresh_perl_is(q{
    use utf8;
    use strict;
    use feature qw(case_match say);
    case (['a', 'b']) {
        match ([/(?<prénom>a)/, /(?<numéro>b)/]) { say "$prénom,$numéro" }
    }
}, 'a,b', {}, 'multiple regex captures preserve UTF-8 lexical names');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    'outside' =~ /(outside)/;
    case (['a', 'b']) {
        match ([/(?<first>a)/, /(?<second>b)/]) {
            say "$first,$second,$1";
        }
    }
    say $1;
}, "a,b,b\noutside", {},
    'each regex supplies its own named captures and restores outer matches');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    case (bless({name => 'Ada', code => '42'}, 'Person')) {
        match (Person {name => /(?<who>\w+)/, code => /(?<id>\d+)/}) {
            say "$who,$id";
        }
    }
}, 'Ada,42', {}, 'named regex captures traverse object field shapes');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say class);
    no warnings 'experimental::class';
    class Person { field $name :param; field $code :param }
    case (Person->new(name => 'Ada', code => '42')) {
        match (Person {'$name' => /(?<who>\w+)/,
                       '$code' => /(?<id>\d+)/}) { say "$who,$id" }
    }
}, 'Ada,42', {}, 'named regex captures traverse native class fields');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    case (['a1', 'bad', 'a2', 'b2']) {
        match ([..., /a(?<first>\d)/, /b(?<second>\d)(?<extra>x)?/, ...]) {
            say "$first,$second," . (defined($extra) ? 'wrong' : 'undef');
        }
    }
}, '2,2,undef', {},
    'open-array retries discard tentative captures from each rejected candidate');

fresh_perl_is(q{
    use feature qw(case_match say);
    for my $n (63, 64, 65, 128, 256) {
        my $values = join ',', 1 .. $n;
        my $bindings = join ',', map { '$x' . $_ } 1 .. $n;
        for my $shape ($values, $bindings) {
            my $result = eval 'case ([' . $values . ']) { match (['
                . $shape . ']) { "hit" } match (_) { "miss" } }';
            die $@ if $@;
            die 'wrong result' unless $result eq 'hit';
        }
    }
    say 'ok';
}, 'ok', {}, 'large arrays and capture sets have no 64-element limit');

fresh_perl_is(q{
    use feature qw(case_match say);
    my $shape = join '.', map { ('"/"', '$x' . $_) } 1 .. 65;
    my $result = eval 'case ("/v" x 65) { match (' . $shape
        . ') { $x1 . $x65 } match (_) { "miss" } }';
    die $@ if $@;
    say $result;
}, 'vv', {}, 'concatenations can capture more than 64 values');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    my $shape = join '', map { '(?<x' . $_ . '>a)' } 1 .. 65;
    my $result = eval 'case ("a" x 65) { match (/' . $shape
        . '/) { $x1 . $x65 } match (_) { "miss" } }';
    die $@ if $@;
    say $result;
}, 'aa', {}, 'regexes can bind more than 64 named captures');

fresh_perl_is(q{
    use feature qw(case_match say);
    use builtin qw(true false);
    my $one = 2; --$one;
    my $zero = 2; $zero -= 2;
    for my $v ($one, $zero, true, false) {
        case ([$v]) {
            match ([true])  { say 'true' }
            match ([false]) { say 'false' }
            match (_)      { say 'not boolean' }
        }
    }
}, "not boolean\nnot boolean\ntrue\nfalse", {},
    'nested builtin boolean constants require actual boolean values');

fresh_perl_is(q{
    use feature qw(case_match say);
    for my $min ('4294967296', '18446744073709551616', '9' x 100) {
        eval 'case ([]) { match ([@rest:' . $min . ']) { 1 } }';
        say $@ =~ /array slurp minimum exceeds 2\*\*32 - 1/
            ? 'rejected' : 'wrong result';
    }
}, "rejected\nrejected\nrejected", {},
    'out-of-range slurp minima are rejected before integer overflow');

fresh_perl_is(q{
    use feature qw(case_match say);
    my (@closures, @refs);
    for (1 .. 3) {
        case ([$_]) {
            match ([$x]) {
                push @closures, sub { $x };
                push @refs, \$x;
            }
        }
    }
    say join ',', map { $_->() } @closures;
    say join ',', map { $$_ } @refs;
}, "1,2,3\n1,2,3", {},
    'escaped scalar bindings retain their values and iteration identity');

fresh_perl_is(q{
    use feature qw(case_match say);
    my @closures;
    for (1 .. 3) {
        case ([$_, $_ + 1]) {
            match ([@tail]) { push @closures, sub { @tail } }
        }
    }
    say join ',', $_->() for @closures;
}, "1,2\n2,3\n3,4", {},
    'escaped slurp bindings retain their values and iteration identity');

{
    package CaseMatchHardeningTail::Destroyed;
    our $destroyed;
    sub DESTROY { $destroyed++ }
}

my ($rollback_value, $rollback_error);
my $exception_rollback_ok = eval q{
    use feature 'case_match';
    case ([ 1, 2 ]) {
        match ([ $rollback_value, $other ] if die 'rollback guard') { 1 }
    }
    1;
};
$rollback_error = $@;
ok(!$exception_rollback_ok && $rollback_error =~ /rollback guard/
   && !defined($rollback_value),
   'bindings roll back when a guard throws');

my ($localized_before, $localized_inside, $localized_after);
my $localization_ok = eval q{
    use feature 'case_match';
    our $case_match_local = 'outer';
    $localized_before = $case_match_local;
    case (1) {
        match (1) {
            local $case_match_local = 'inner';
            $localized_inside = $case_match_local;
        }
    }
    $localized_after = $case_match_local;
    1;
};
ok(!$@ && $localization_ok && $localized_before eq 'outer'
   && $localized_inside eq 'inner' && $localized_after eq 'outer',
   'localization in a clause is restored normally');

my ($destroyed_inside, $destroyed_after);
sub destruction_probe {
    use feature 'case_match';
    my $value = bless {}, 'CaseMatchHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    case ($value) { match (ObjectVal($object)) { $destroyed_inside = ref($object) } }
    undef $value;
    return !defined($weak);
}
my $destruction_ok = eval { destruction_probe() };
$destroyed_after = $CaseMatchHardeningTail::Destroyed::destroyed;
ok(!$@ && $destruction_ok && $destroyed_inside eq 'CaseMatchHardeningTail::Destroyed'
   && $destroyed_after,
   'captured objects are released after the case scope ends');

sub exception_release_probe {
    use feature 'case_match';
    my $value = bless {}, 'CaseMatchHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    eval {
        case ($value) {
            match (ObjectVal($object)) { die 'release from clause' }
        }
    };
    my $error = $@;
    undef $value;
    return $error, !defined($weak);
}
my ($exception_release_error, $exception_released) = exception_release_probe();
ok($exception_release_error =~ /release from clause/ && $exception_released,
   'captured objects are released when a clause dies');

sub array_binding_release_probe {
    use feature 'case_match';
    my $value = bless {}, 'CaseMatchHardeningTail::Destroyed';
    my $weak = $value;
    my $subject = [ $value ];
    Scalar::Util::weaken($weak);
    case ($subject) {
        match ([ $captured ]) { 1 }
    }
    undef $subject;
    undef $value;
    return !defined($weak);
}
ok(array_binding_release_probe(),
   'captured objects in aggregate bindings are released at case exit');

sub returned_binding_survives_cleanup {
    use feature 'case_match';
    my $value = bless {}, 'CaseMatchHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    my $result = do {
        case ($value) {
            match (ObjectVal($object)) { $object }
        }
    };
    undef $value;
    my $ok = ref($result) eq 'CaseMatchHardeningTail::Destroyed'
        && defined($weak);
    undef $result;
    return $ok && !defined($weak);
}
ok(returned_binding_survives_cleanup(),
   'case cleanup does not invalidate a value returned by a clause');

my ($nested_result, $nested_outer_result);
my $nested_case_ok = eval q{
    use feature 'case_match';
    $nested_result = do { case ([ 1, 2 ]) {
        match ([ 1, $x ]) {
            case ($x) { match (2) { 'inner' } }
        }
    } };
    $nested_outer_result = do { case (1) { match (1) { 'outer' } } };
    1;
};
ok(!$@ && $nested_case_ok && $nested_result eq 'inner'
   && $nested_outer_result eq 'outer',
   'nested cases restore the parent case state');

for my $target (qw(x px)) {
    my $program = q{
        use strict;
        use feature qw(case_match say);
        use experimental 'class';
        class Position {
            field $x :param;
            field $y :param;
        }
        case (Position->new(x => 3, y => 4)) {
            match (Position { '$x' => $TARGET, '$y' => $other }
                   if $TARGET == 3 && $other == 4) {
                say "$TARGET,$other";
            }
        }
    };
    $program =~ s/TARGET/$target/g;
    fresh_perl_is($program, '3,4', {},
        "native class fields bind implicit target \$$target in guard and body");
}

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    my ($x, $y) = ('outer x', 'outer y');
    my $point = bless { x => 3, y => 4 }, 'Point';
    case ($point) {
        match (Point { 'x' => $x, 'y' => $y } if $x == 3) {
            say "$x,$y";
        }
    }
    say "$x,$y";
}, "3,4\nouter x,outer y", {},
    'class-qualified captures shadow rather than overwrite outer lexicals');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    my $record = bless {
        child => bless({ values => [3, 4, 5] }, 'Child'),
    }, 'Record';
    case ($record) {
        match (Record {
            'child' => Child { 'values' => [$head, @tail] },
        } if $head == 3 && @tail == 2) {
            say "$head:@tail";
        }
    }
}, '3:4 5', {},
    'nested object shapes expose scalar and array captures to the clause');

fresh_perl_is(q{
    use feature qw(case_match say);
    use experimental 'class';
    class Position {
        field $x :param;
        field $y :param;
    }
    case (Position->new(x => 3, y => 4)) {
        match (Position { '$x' => $x, '$y' => $y }) {
            say "position: $x, $y";
        }
    }
}, 'position: 3, 4', {},
    'native captures named after fields do not select class field pad entries');

fresh_perl_is(q{
    use strict;
    use feature qw(case_match say);
    my $wanted = 'ok';
    my $value = 'outside';
    my $record = bless { status => 'ok', value => 3 }, 'Record';
    case ($record) with ($wanted) {
        match (Record { 'status' => $wanted, 'value' => $value }
               if $value == 4) { die 'wrong guard' }
        match (Record { 'status' => ^$wanted, 'value' => Int($value) }
               if $value == 3) { say $value }
    }
    say "$wanted,$value";
}, "3\nok,outside", {},
    'object pins and typed captures retain scope across a failed guard');

fresh_perl_is(q{
    use strict;
    use utf8;
    use feature qw(case_match say);
    for (1 .. 3) {
        case ([bless({ value => $_ }, 'Record')]) {
            match ([Record { 'value' => $résultat }]) {
                say $résultat;
            }
        }
    }
}, "1\n2\n3", {},
    'object captures nested in arrays preserve UTF-8 names and repeated use');

fresh_perl_is(q{
    use feature qw(case_match say);
    for (1 .. 3) {
        my $result = eval q{
            case ([]) {
                match ([@rest:4294967295]) { die 'tail too short' }
                match (_) { 'miss' }
            }
        };
        die $@ if $@;
        say $result;
    }
}, "miss\nmiss\nmiss", {},
    'freeing a slurp pattern does not treat its minimum as a pad index');
