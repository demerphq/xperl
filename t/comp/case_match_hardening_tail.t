#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

plan(6);

require Scalar::Util;

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
