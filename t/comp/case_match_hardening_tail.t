#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

plan(17);

require Scalar::Util;

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
