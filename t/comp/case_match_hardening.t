#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

plan(14);

{
    package CaseMatchHardening::ScalarTie;
    our ($fetches, $stores);
    sub TIESCALAR { bless { value => $_[1] }, $_[0] }
    sub FETCH { $fetches++; $_[0]{value} }
    sub STORE { $stores++; $_[0]{value} = $_[1] }
}

{
    package CaseMatchHardening::ArrayTie;
    our ($fetches, $sizes);
    sub TIEARRAY { bless { values => [ @{ $_[1] } ] }, $_[0] }
    sub FETCH { $fetches++; $_[0]{values}[$_[1]] }
    sub FETCHSIZE { $sizes++; scalar @{ $_[0]{values} } }
}

{
    package CaseMatchHardening::HashTie;
    our ($fetches, $exists);
    sub TIEHASH { bless { values => { %{ $_[1] } } }, $_[0] }
    sub FETCH { $fetches++; $_[0]{values}{$_[1]} }
    sub EXISTS { $exists++; exists $_[0]{values}{$_[1]} }
    sub FIRSTKEY { my $self = shift; keys %{ $self->{values} }; each %{ $self->{values} } }
    sub NEXTKEY { my $self = shift; each %{ $self->{values} } }
}

{
    package CaseMatchHardening::Stringified;
    our $stringifications;
    use overload '""' => sub { $stringifications++; $_[0]{value} },
                 fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

{
    package CaseMatchHardening::Destroyed;
    our $destroyed;
    sub new { bless {}, $_[0] }
    sub DESTROY { $destroyed++ }
}

require Scalar::Util;

my ($scalar_result, @list_result, $void_result);
use feature 'case_match';
sub clause_context {
    return wantarray ? ('list', 'result') : 'scalar';
}
sub clause_void_context {
    $void_result = !defined(wantarray);
}
$scalar_result = do {
    case (1) { match (1) { clause_context() } }
};
@list_result = do {
    case (1) { match (1) { clause_context() } }
};
case (1) { match (1) { clause_void_context() } };
ok($scalar_result eq 'scalar'
   && @list_result == 2 && $list_result[0] eq 'list'
   && $list_result[1] eq 'result' && $void_result,
   'selected clause expressions receive scalar, list, and void context');

my ($empty_matched, $empty_scalar, @empty_list);
my $empty_result_ok = eval q{
    use feature 'case_match';
    $empty_scalar = do { case (1) { match (1) { $empty_matched++; () } } };
    @empty_list = do { case (1) { match (1) { $empty_matched++; () } } };
    1;
};
ok(!$@ && $empty_result_ok && $empty_matched == 2
   && !defined($empty_scalar) && !@empty_list,
   'a matched clause returning an empty list still runs');

my ($no_scalar, @no_list, $no_void);
my $no_match_context_ok = eval q{
    use feature 'case_match';
    $no_scalar = do { case (2) { match (1) { 1 } } };
    @no_list = do { case (2) { match (1) { 1 } } };
    case (2) { match (1) { $no_void = 1 } };
    1;
};
ok(!$@ && $no_match_context_ok && !defined($no_scalar)
   && !@no_list && !defined($no_void),
   'no-match result follows scalar, list, and void context');

my ($subject_fetches, $subject_result);
my $subject_once_ok = eval q{
    use feature 'case_match';
    my $subject;
    tie $subject, 'CaseMatchHardening::ScalarTie', 7;
    $CaseMatchHardening::ScalarTie::fetches = 0;
    $subject_result = do { case ($subject) {
        match (7) { $subject = 8; 1 }
    } };
    $subject_fetches = $CaseMatchHardening::ScalarTie::fetches;
    1;
};
ok(!$@ && $subject_once_ok && $subject_result == 1
   && $subject_fetches == 1,
   'matching fetches a tied scalar subject once');

my $subject_write_ok = eval q{
    use feature 'case_match';
    my $subject;
    tie $subject, 'CaseMatchHardening::ScalarTie', 7;
    case ($subject) { match (7) { $subject = 9 } };
    $subject == 9;
};
ok(!$@ && $subject_write_ok, 'a clause can write the original scalar subject');

my ($tied_array_result, $array_fetches, $array_sizes);
my $tied_array_ok = eval q{
    use feature 'case_match';
    my @subject;
    tie @subject, 'CaseMatchHardening::ArrayTie', [ 1, 2 ];
    $CaseMatchHardening::ArrayTie::fetches = 0;
    $CaseMatchHardening::ArrayTie::sizes = 0;
    $tied_array_result = do { case (\@subject) {
        match ([ 1, $value ]) { $value }
    } };
    $array_fetches = $CaseMatchHardening::ArrayTie::fetches;
    $array_sizes = $CaseMatchHardening::ArrayTie::sizes;
    1;
};
ok(!$@ && $tied_array_ok && $tied_array_result == 2
   && $array_fetches && $array_sizes,
   'matching reads tied array values through normal magic');

my ($tied_hash_result, $hash_fetches, $hash_exists);
my $tied_hash_ok = eval q{
    use feature 'case_match';
    my %subject;
    tie %subject, 'CaseMatchHardening::HashTie', { answer => 42 };
    $CaseMatchHardening::HashTie::fetches = 0;
    $CaseMatchHardening::HashTie::exists = 0;
    $tied_hash_result = do { case (\%subject) {
        match ({ answer => $answer }) { $answer }
    } };
    $hash_fetches = $CaseMatchHardening::HashTie::fetches;
    $hash_exists = $CaseMatchHardening::HashTie::exists;
    1;
};
ok(!$@ && $tied_hash_ok && $tied_hash_result == 42
   && $hash_fetches,
   'matching reads tied hash values through normal magic');

my ($stringified_result, $stringifications);
my $overload_ok = eval q{
    use feature 'case_match';
    my $value = CaseMatchHardening::Stringified->new('target');
    $CaseMatchHardening::Stringified::stringifications = 0;
    $stringified_result = do { case ($value) {
        match ('target') { 1 }
    } };
    $stringifications = $CaseMatchHardening::Stringified::stringifications;
    1;
};
ok(!$@ && $overload_ok && $stringified_result == 1
   && $stringifications,
   'string matching invokes the selected string overload');

my ($structural_result, $structural_stringifications);
my $structural_overload_ok = eval q{
    use feature 'case_match';
    my $value = bless { value => 'target' }, 'CaseMatchHardening::Stringified';
    $CaseMatchHardening::Stringified::stringifications = 0;
    $structural_result = do { case ($value) {
        match (ObjectVal($object)) { Scalar::Util::refaddr($object) == Scalar::Util::refaddr($value) }
    } };
    $structural_stringifications = $CaseMatchHardening::Stringified::stringifications;
    1;
};
ok(!$@ && $structural_overload_ok && $structural_result
   && !$structural_stringifications,
   'structural object matching does not stringify the whole object');

my ($captured_ref, $original_ref);
my $identity_ok = eval q{
    use feature 'case_match';
    my $value = [ 1, 2 ];
    $original_ref = Scalar::Util::refaddr($value);
    case ($value) {
        match (RefVal($captured)) { $captured_ref = Scalar::Util::refaddr($captured) }
    }
    1;
};
ok(!$@ && $identity_ok && $captured_ref == $original_ref,
   'reference captures preserve referent identity');

my ($array_changed, $hash_changed);
my $aggregate_mutation_ok = eval q{
    use feature 'case_match';
    my $array = [ 1, 2 ];
    case ($array) { match ([ 1, $value ]) { $array->[1] = 9 } };
    $array_changed = $array->[1] == 9;
    my $hash = { value => 1 };
    case ($hash) { match ({ value => $value }) { $hash->{value} = 8 } };
    $hash_changed = $hash->{value} == 8;
    1;
};
ok(!$@ && $aggregate_mutation_ok && $array_changed && $hash_changed,
   'a clause can mutate the original array and hash subjects');

my ($subject_die, $pattern_die, $guard_die, $body_die);
my $exception_ok = eval q{
    use feature 'case_match';
    eval { case (die 'subject failure') { match (_) { 1 } } };
    $subject_die = $@;
    sub die_pattern { die 'pattern failure' }
    eval { case (1) { match (die_pattern()) { 1 } } };
    $pattern_die = $@;
    eval { case (1) { match (1 if die 'guard failure') { 1 } } };
    $guard_die = $@;
    eval { case (1) { match (1) { die 'body failure' } } };
    $body_die = $@;
    1;
};
ok(!$@ && $exception_ok && $subject_die =~ /subject failure/
   && $pattern_die =~ /pattern failure/
   && $guard_die =~ /guard failure/
   && $body_die =~ /body failure/,
   'exceptions from subject, pattern, guard, and body propagate to eval');

my ($nested_caught, $nested_after);
my $nested_eval_ok = eval q{
    use feature 'case_match';
    case (1) {
        match (1) {
            $nested_caught = eval { case (die 'inner') { match (_) { 1 } } };
            $nested_after = $@ =~ /inner/;
        }
    }
    1;
};
ok(!$@ && $nested_eval_ok && !defined($nested_caught) && $nested_after,
   'an inner eval catches an exception without aborting its clause');

my ($outer_error, $after_error);
my $outer_eval_ok = eval q{
    use feature 'case_match';
    eval { case (1) { match (1) { die 'uncaught clause' } } };
    $outer_error = $@;
    $after_error = do { case (2) { match (1) { 1 } } };
    1;
};
ok(!$@ && $outer_eval_ok && $outer_error =~ /uncaught clause/
   && !defined($after_error),
   'case state is restored after an exception and later cases still run');
