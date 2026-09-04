#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
}

print "1..68\n";

my $ran = 0;
$_ = 'outside';
my $ok = eval q{
    use feature 'case_match';
    case (1) {
        match (1) { $ran = 1; }
    }
    1;
};
print !$@ && $ok && $ran ? "ok 1 - case and match syntax\n"
                         : "not ok 1 - case and match syntax\n";

my $off = eval q{ case (1) { match (1) {} } 1 };
print $@ ? "ok 2 - feature gated\n" : "not ok 2 - feature gated\n";

my $nested = eval q{
    use feature 'case_match';
    case (2) {
        match (1) { die 'wrong clause'; }
        match (2) { $ran = 2; }
    }
    1;
};
print !$@ && $nested && $ran == 2 ? "ok 3 - multiple clauses\n"
                                  : "not ok 3 - multiple clauses\n";
print $_ eq 'outside' ? "ok 4 - does not leak $_\n"
                      : "not ok 4 - does not leak $_\n";

my ($numeric, $string) = (0, 0);
my $typed_numeric = eval q{
    use feature 'case_match';
    case (123) {
        match (123) { $numeric = 1; }
        match ('123') { $string = 1; }
    }
    1;
};
my $typed_string = eval q{
    use feature 'case_match';
    case ('123') {
        match (123) { $numeric = 2; }
        match ('123') { $string = 2; }
    }
    1;
};
print !$@ && $typed_numeric && $typed_string
    && $numeric == 1 && $string == 2
    ? "ok 5 - typed literals\n"
    : "not ok 5 - typed literals\n";

my $wildcard = eval q{
    use feature 'case_match';
    case (999) {
        match (_) { 1; }
    }
};
print !$@ && $wildcard ? "ok 6 - wildcard\n" : "not ok 6 - wildcard\n";

my ($first, $second, $nested_first, $nested_second);
my $nested = eval q{
    use feature 'case_match';
    case ([ { foo => 1 }, { foo => 2 } ]) {
        match ([ { foo => $first }, { foo => $second } ]) {
            $nested_first = $first;
            $nested_second = $second;
            1;
        }
    }
};
print !$@ && $nested && $nested_first == 1 && $nested_second == 2
    ? "ok 7 - nested captures\n" : "not ok 7 - nested captures\n";

my $rollback = eval q{
    use feature 'case_match';
    case ([ { foo => 1 }, { bar => 2 } ]) {
        match ([ { foo => $first }, { foo => $second } ]) { 1; }
    }
};
print !$@ && !defined($rollback)
    ? "ok 8 - failed match rolls back\n"
    : "not ok 8 - failed match rolls back\n";

my $open_array = eval q{
    use feature 'case_match';
    case ([ 1, 2, 3 ]) {
        match ([ 1, ... ]) { 1; }
    }
    1;
};
print !$@ && $open_array ? "ok 9 - open array pattern\n"
                         : "not ok 9 - open array pattern\n";

my $open_hash = eval q{
    use feature 'case_match';
    case ({ foo => 1, bar => 2 }) {
        match ({ foo => 1, ... }) { 1; }
    }
    1;
};
print !$@ && $open_hash ? "ok 10 - open hash pattern\n"
                        : "not ok 10 - open hash pattern\n";

my $open_prefix = eval q{
    use feature 'case_match';
    case ([ 1, 2, 3 ]) {
        match ([ ..., 3 ]) { 1; }
    }
    1;
};
print !$@ && $open_prefix ? "ok 11 - open prefix pattern\n"
                          : "not ok 11 - open prefix pattern\n";

my $subsequence;
my $subsequence_result;
my $open_both = eval q{
    use feature 'case_match';
    case ([ 0, 'foo', 10, 'bar', 20, 'foo', 30, 'bar' ]) {
        match ([ ..., 'foo', $subsequence, 'bar', ... ]) {
            $subsequence_result = $subsequence;
            1;
        }
    }
    1;
};
print !$@ && $open_both && $subsequence_result == 10
    ? "ok 12 - leftmost subsequence pattern\n"
    : "not ok 12 - leftmost subsequence pattern\n";

my $nested_open;
my $nested_value;
my $nested_value_result;
my $nested_open_ok = eval q{
    use feature 'case_match';
    case ([ { foo => 1 }, { foo => 2 }, { foo => 3 } ]) {
        match ([ { foo => $nested_value }, ... ]) {
            $nested_open = 1;
            $nested_value_result = $nested_value;
        }
    }
    1;
};
print !$@ && $nested_open_ok && $nested_open && $nested_value_result == 1
    ? "ok 13 - nested open pattern\n"
    : "not ok 13 - nested open pattern\n";

my $dynamic_array = eval q{
    use feature 'case_match';
    my $offset = 2;
    case ([ 3 ]) {
        match ([ $offset + 1 ]) { 1; }
    }
    1;
};
print !$@ && $dynamic_array ? "ok 14 - dynamic nested array pattern\n"
                            : "not ok 14 - dynamic nested array pattern\n";

my $dynamic_hash = eval q{
    use feature 'case_match';
    my $offset = 2;
    case ({ foo => 3 }) {
        match ({ foo => $offset + 1 }) { 1; }
    }
    1;
};
print !$@ && $dynamic_hash ? "ok 15 - dynamic nested hash pattern\n"
                           : "not ok 15 - dynamic nested hash pattern\n";

my $regex_match = eval q{
    use feature 'case_match';
    case ('abc') {
        match (/b/) { 1; }
    }
    1;
};
print !$@ && $regex_match ? "ok 16 - regex pattern\n"
                          : "not ok 16 - regex pattern\n";

{
    package CaseMatch::Tie;
    our $fetches;
    sub TIESCALAR { bless {}, shift }
    sub FETCH { $fetches++; 7 }
    sub STORE { $_[0]{value} = $_[1] }
}

my $subject;
tie $subject, 'CaseMatch::Tie';
my $changed;
my $snapshot = eval q{
    use feature 'case_match';
    case ($subject) {
        match (7) { $subject = 9; $changed = 1; }
    }
    1;
};
print !$@ && $snapshot && $changed && $CaseMatch::Tie::fetches == 1
    ? "ok 17 - subject fetched once\n"
    : "not ok 17 - subject fetched once\n";
print $subject == 7 ? "ok 18 - clause can write subject\n"
                    : "not ok 18 - clause can write subject\n";

my $clause_result = eval q{
    use feature 'case_match';
    do {
        case (1) {
            match (1) { 7; 42; }
        }
    }
};
print !$@ && defined($clause_result) && $clause_result == 42
    ? "ok 19 - case returns the clause's last expression\n"
    : "not ok 19 - case returns the clause's last expression\n";

my @clause_result = eval q{
    use feature 'case_match';
    do {
        case (1) {
            match (1) { (7, 42) }
        }
    }
};
print !$@ && @clause_result == 2 && $clause_result[0] == 7 && $clause_result[1] == 42
    ? "ok 20 - case preserves list context\n"
    : "not ok 20 - case preserves list context\n";

my $no_match = eval q{
    use feature 'case_match';
    do {
        case (2) {
            match (1) { 42 }
        }
    }
};
my @no_match = eval q{
    use feature 'case_match';
    do {
        case (2) {
            match (1) { 42 }
        }
    }
};
print !$@ && !defined($no_match) && !@no_match
    ? "ok 21 - no match returns undef or an empty list\n"
    : "not ok 21 - no match returns undef or an empty list\n";

my $default = eval q{
    use feature 'case_match';
    do {
        case ('other') {
            match ('expected') { die 'wrong clause'; }
            match (_) { 99 }
        }
    }
};
print !$@ && defined($default) && $default == 99
    ? "ok 22 - wildcard clause is the default\n"
    : "not ok 22 - wildcard clause is the default\n";

my $named_subject = eval q{
    use feature qw(case_match namespaces);
    do {
        case (21 as $bound) {
            match (21) { $bound }
        }
    }
};
print !$@ && defined($named_subject) && $named_subject == 21
    ? "ok 23 - case binds a named subject\n"
    : "not ok 23 - case binds a named subject\n";

my $scope_error = eval q{
    use feature qw(case_match namespaces);
    no warnings 'syntax';
    do {
        case (21 as $bound) {
            match (21) { 1 }
        }
    }
    $bound;
};
print $@ ? "ok 24 - named subject is case-local\n"
         : "not ok 24 - named subject is case-local\n";

my $guard_capture;
my $guard_fallback = eval q{
    use feature 'case_match';
    do {
        case ([1]) {
            match ([$guard_capture] if $guard_capture == 2) { die 'wrong clause'; }
            match (_) { 88 }
        }
    }
};
print !$@ && $guard_fallback == 88 && !defined($guard_capture)
    ? "ok 25 - failed guard rolls back captures\n"
    : "not ok 25 - failed guard rolls back captures\n";

my $guard_success = eval q{
    use feature 'case_match';
    do {
        case ([1]) {
            match ([$guard_capture] if $guard_capture == 1) { $guard_capture }
        }
    }
};
print !$@ && defined($guard_success) && $guard_success == 1
    ? "ok 26 - guard can use captures\n"
    : "not ok 26 - guard can use captures\n";

undef $guard_capture;
my $guard_exception = eval q{
    use feature 'case_match';
    case ([1]) {
        match ([$guard_capture] if die 'guard failure') { 1 }
    }
};
print $@ && !defined($guard_capture)
    ? "ok 27 - guard exceptions restore captures\n"
    : "not ok 27 - guard exceptions restore captures\n";

my $with_ok = eval q{
    use feature 'case_match';
    my ($left, $right) = (1, 2);
    case ({ left => 1, right => 2 }) with ($left, $right) {
        match ({ left => $left, right => $right }) { 1 }
    }
};
print !$@ && $with_ok == 1 ? "ok 28 - with pins lexical values\n"
                           : "not ok 28 - with pins lexical values\n";

my $with_mismatch = eval q{
    use feature 'case_match';
    my $left = 9;
    case ({ left => 1 }) with ($left) {
        match ({ left => $left }) { 1 }
    }
};
print !$@ && !defined($with_mismatch)
    ? "ok 29 - with rejects a mismatched pin\n"
    : "not ok 29 - with rejects a mismatched pin\n";

my $ordinary_case_statement = eval q{
    use feature 'case_match';
    case (1) {
        1;
        match (1) { 2 }
    }
};
print $@ =~ /only match clauses are allowed directly in a case/
    ? "ok 30 - case body rejects ordinary statements\n"
    : "not ok 30 - case body rejects ordinary statements\n";

my $ordinary_clause_block = eval q{
    use feature 'case_match';
    case (1) {
        match (1) {
            my $value = 0;
            for (1 .. 2) {
                $value += $_;
            }
            $value;
        }
    }
};
print !$@ && defined($ordinary_clause_block) && $ordinary_clause_block == 3
    ? "ok 31 - match clause retains ordinary block syntax\n"
    : "not ok 31 - match clause retains ordinary block syntax\n";

my $nested_case_in_clause = eval q{
    use feature 'case_match';
    my $value;
    case (1) {
        match (1) {
            case (2) {
                match (2) { $value = 7 }
            }
        }
    }
    $value;
};
print !$@ && defined($nested_case_in_clause) && $nested_case_in_clause == 7
    ? "ok 32 - nested case is valid inside a clause\n"
    : "not ok 32 - nested case is valid inside a clause\n";

my $nested_case_as_clause = eval q{
    use feature 'case_match';
    case (1) {
        case (1) { match (1) { 7 } }
    }
};
print $@ =~ /only match clauses are allowed directly in a case/
    ? "ok 33 - nested case is not a clause\n"
    : "not ok 33 - nested case is not a clause\n";

my ($coerced_int, $coerced_float, $coerced_string) = (0, 0, 0);
my ($coerced_undef, $coerced_ref) = (0, 0);
my $typed_subjects = eval q{
    use feature 'case_match';
    case (IntVal '12') {
        match (12) { $coerced_int = 1 }
    }
    case (FloatVal '2.5') {
        match (2.5) { $coerced_float = 1 }
    }
    case (StrVal 12) {
        match ('12') { $coerced_string = 1 }
    }
    case (StrVal undef) {
        match (undef) { $coerced_undef = 1 }
    }
    my $ref = [];
    case (IntVal $ref) {
        match (_) { $coerced_ref = ref($ref) eq 'ARRAY' }
    }
    1;
};
print !$@ && $typed_subjects && $coerced_int && $coerced_float
    && $coerced_string && $coerced_undef && $coerced_ref
    ? "ok 34 - typed case subjects\n"
    : "not ok 34 - typed case subjects\n";

my $undef_pattern = eval q{
    use feature 'case_match';
    case (undef) {
        match (undef) { 1 }
    }
};
print !$@ && defined($undef_pattern) && $undef_pattern == 1
    ? "ok 35 - undef is a literal pattern\n"
    : "not ok 35 - undef is a literal pattern\n";

my $typed_reference = [];
my $typed_reference_result = eval q{
    use feature 'case_match';
    case (StrVal $typed_reference) {
        match ($typed_reference) { 1 }
    }
};
print !$@ && $typed_reference_result
    ? "ok 36 - typed subjects preserve references\n"
    : "not ok 36 - typed subjects preserve references\n";

my ($typed_expression, $typed_parenthesized) = (undef, undef);
my $typed_expression_result = eval q{
    use feature qw(case_match namespaces);
    my $x = 1;
    case (StrVal $x + 1 as $bound) {
        match ('2') { $typed_expression = $bound }
    }
    case (StrVal($x + 1) as $bound) {
        match ('2') { $typed_parenthesized = $bound }
    }
    1;
};
print !$@ && $typed_expression_result
    && $typed_expression eq '2' && $typed_parenthesized eq '2'
    ? "ok 37 - typed subject expressions bind equivalently\n"
    : "not ok 37 - typed subject expressions bind equivalently\n";

my $with_expression = eval q{
    use feature qw(case_match namespaces);
    my $base = 4;
    my $evaluations = 0;
    case (8) with (++$evaluations + $base as $expected) {
        match ($expected) { 1 }
    }
    $evaluations == 1;
};
print !$@ && $with_expression
    ? "ok 38 - with expression pins a case-local value\n"
    : "not ok 38 - with expression pins a case-local value\n";

my ($bool_yes, $bool_no, $bool_number) = (0, 0, 0);
my $typed_boolean = eval q{
    use feature 'case_match';
    use builtin qw(true false);
    case (true)  { match (true)  { $bool_yes = 1 } }
    case (false) { match (false) { $bool_no = 1 } }
    case (1)     { match (true)  { $bool_number = 1 } }
    1;
};
print !$@ && $typed_boolean && $bool_yes && $bool_no && $bool_number
    ? "ok 39 - boolean literals use truth-value semantics\n"
    : "not ok 39 - boolean literals use truth-value semantics\n";

my ($dispatch_order, $dispatch_duplicate, $dispatch_miss) = (0, 0, 0);
my $constant_dispatch = eval q{
    use feature 'case_match';
    use builtin qw(true false);
    case (1) {
        match ('1') { $dispatch_order = 1 }
        match (true) { $dispatch_order = 2 }
        match (1) { $dispatch_order = 3 }
    }
    case (1) {
        match (1) { $dispatch_duplicate++ }
        match (1) { $dispatch_duplicate += 10 }
    }
    case (3) {
        match (1) { $dispatch_miss = 1 }
    }
    1;
};
print !$@ && $constant_dispatch && $dispatch_order == 2
    && $dispatch_duplicate == 1 && !$dispatch_miss
    ? "ok 40 - constant dispatch preserves typed source order\n"
    : "not ok 40 - constant dispatch preserves typed source order\n";

my ($dispatch_default, $dispatch_early_default) = (0, 0);
my $constant_dispatch_default = eval q{
    use feature 'case_match';
    case (99) {
        match (1) { $dispatch_default = 1 }
        match (_) { $dispatch_default = 2 }
    }
    case (99) {
        match (_)  { $dispatch_early_default = 3 }
        match (99) { $dispatch_early_default = 4 }
    }
    1;
};
print !$@ && $constant_dispatch_default
    && $dispatch_default == 2 && $dispatch_early_default == 3
    ? "ok 41 - constant dispatch preserves wildcard defaults\n"
    : "not ok 41 - constant dispatch preserves wildcard defaults\n";

my ($empty_default_scalar, @empty_default_list);
my $empty_default_result = eval q{
    use feature 'case_match';
    $empty_default_scalar = sub {
        case (99) {
            match (1) { 1 }
            match (_) { () }
        }
    }->();
    @empty_default_list = sub {
        case (99) {
            match (1) { 1 }
            match (_) { () }
        }
    }->();
    1;
};
print !$@ && $empty_default_result && !defined($empty_default_scalar)
    && !@empty_default_list
    ? "ok 42 - empty wildcard default preserves context\n"
    : "not ok 42 - empty wildcard default preserves context\n";

my ($last_label, $next_label, $redo_label) = (0, 0, 0);
my $label_control = eval q{
    use feature 'case_match';
    LABEL_LAST: case (1) {
        match (1) { $last_label = 1; last LABEL_LAST; $last_label = 2 }
    }
    LABEL_NEXT: case (1) {
        match (1) { $next_label = 1; next LABEL_NEXT; $next_label = 2 }
    }
    my $n = 0;
    LABEL_REDO: case (++$n) {
        match (1) { redo LABEL_REDO }
        match (_) { $redo_label = $n }
    }
    1;
};
print !$@ && $label_control && $last_label == 1 && $next_label == 1
    && $redo_label == 2
    ? "ok 43 - labelled case control exits and redoes correctly\n"
    : "not ok 43 - labelled case control exits and redoes correctly\n";

my ($captured_suffix, $unchanged_suffix, $empty_suffix) = ();
my ($captured_suffix_result, $empty_suffix_result);
my $concat_capture = eval q{
    use feature 'case_match';
    my $text = 'foo_bar';
    case ($text) {
        match ('foo_' . $captured_suffix) {
            $captured_suffix_result = $captured_suffix;
        }
    }
    $text = 'foo_';
    case ($text) {
        match ('foo_' . $empty_suffix) {
            $empty_suffix_result = $empty_suffix;
        }
    }
    $text = 'not_bar';
    $unchanged_suffix = 'OLD';
    case ($text) {
        match ('foo_' . $unchanged_suffix) { 1 }
    }
    1;
};
print !$@ && $concat_capture && $captured_suffix_result eq 'bar'
    && $empty_suffix_result eq '' && $unchanged_suffix eq 'OLD'
    ? "ok 44 - concatenation captures an unpinned suffix\n"
    : "not ok 44 - concatenation captures an unpinned suffix\n";

my ($pinned_match, $pinned_miss) = (0, 0);
my $concat_pin = eval q{
    use feature 'case_match';
    my $p = 'bar';
    case ('foo_bar') with ($p) {
        match ('foo_' . $p) { $pinned_match = $p eq 'bar' }
    }
    $p = 'baz';
    case ('foo_bar') with ($p) {
        match ('foo_' . $p) { $pinned_miss = 1 }
    }
    1;
};
print !$@ && $concat_pin && $pinned_match && !$pinned_miss
    ? "ok 45 - pinned concatenation compares its complete value\n"
    : "not ok 45 - pinned concatenation compares its complete value\n";

my ($sandwich, $leading, $trailing) = ();
my ($sandwich_result, $leading_result, $trailing_result);
my $concat_shapes = eval q{
    use feature 'case_match';
    case ('xmiddlez') {
        match ('x' . $sandwich . 'z') { $sandwich_result = $sandwich }
    }
    case ('middlez') {
        match ($leading . 'z') { $leading_result = $leading }
    }
    case ('xmiddle') {
        match ('x' . $trailing) { $trailing_result = $trailing }
    }
    1;
};
print !$@ && $concat_shapes && $sandwich_result eq 'middle'
    && $leading_result eq 'middle' && $trailing_result eq 'middle'
    ? "ok 46 - concatenation supports prefix suffix and sandwich forms\n"
    : "not ok 46 - concatenation supports prefix suffix and sandwich forms\n";

my $strict_wildcard = eval q{
    use v5.45.3;
    use feature 'case_match';
    case (10) {
        match (_) { 1 }
    }
};
print !$@ && $strict_wildcard
    ? "ok 47 - wildcard works with strict subs\n"
    : "not ok 47 - wildcard works with strict subs\n";

my ($scope_label, $scope_p, $scope_q) = ('outer', 'outer', 'outer');
my @pattern_warnings;
my $implicit_bindings;
{
    local $SIG{__WARN__} = sub { push @pattern_warnings, @_ };
    $implicit_bindings = eval q{
        use strict;
        use warnings;
        use feature 'case_match';
        case ('pfx_whatzit_thing') {
            match ('pfx_' . $label . '_thing' if $label eq 'whatzit') {
                $scope_label = $label;
            }
        }
        case (['a', 1, 2]) {
            match (['a', $p, $q] if $p == 1) {
                $scope_p = $p;
                $scope_q = $q;
            }
        }
        1;
    };
}
print !$@ && $implicit_bindings && !@pattern_warnings
    && $scope_label eq 'whatzit' && $scope_p == 1 && $scope_q == 2
    ? "ok 48 - pattern names are implicit clause-local bindings\n"
    : "not ok 48 - pattern names are implicit clause-local bindings\n";

my $match_outside_case = eval q{
    use feature 'case_match';
    match (1) { 1 }
};
print $match_outside_case eq '' && $@ =~ /only allowed directly in a case/
    ? "ok 49 - match is forbidden outside case\n"
    : "not ok 49 - match is forbidden outside case\n";

my ($ref_kind, $scalar_kind, $undef_kind, $object_kind, $plain_ref_kind);
my $value_kinds = eval q{
    use feature 'case_match';
    my $plain = [];
    my $object = bless {}, 'CaseMatchTestObject';

    case ($plain) {
        match (ObjectVal()) { $object_kind = 1 }
        match (RefVal())    { $ref_kind = 1 }
    }
    case (42) {
        match (RefVal())    { $plain_ref_kind = 1 }
        match (ScalarVal()) { $scalar_kind = 1 }
    }
    case (undef) {
        match (ScalarVal()) { $undef_kind = 1 }
    }
    case ($object) {
        match (ObjectVal()) { $object_kind = 2 }
    }
    1;
};
print !$@ && $value_kinds && $ref_kind == 1
    ? "ok 50 - RefVal matches unblessed references\n"
    : "not ok 50 - RefVal matches unblessed references\n";
print !$@ && $value_kinds && $scalar_kind && !$plain_ref_kind
    ? "ok 51 - ScalarVal matches non-references\n"
    : "not ok 51 - ScalarVal matches non-references\n";
print !$@ && $value_kinds && $undef_kind
    ? "ok 52 - ScalarVal includes undef\n"
    : "not ok 52 - ScalarVal includes undef\n";
print !$@ && $value_kinds && $object_kind == 2
    ? "ok 53 - ObjectVal matches blessed references\n"
    : "not ok 53 - ObjectVal matches blessed references\n";

my ($object_ref, $object_scalar);
my $object_subset = eval q{
    use feature 'case_match';
    my $plain = {};
    case ($plain) {
        match (ObjectVal()) { $object_ref = 1 }
        match (RefVal())    { $object_ref = 2 }
    }
    case ('value') {
        match (ObjectVal()) { $object_scalar = 1 }
        match (ScalarVal()) { $object_scalar = 2 }
    }
    1;
};
print !$@ && $object_subset && $object_ref == 2
    ? "ok 54 - ObjectVal is a subset of RefVal\n"
    : "not ok 54 - ObjectVal is a subset of RefVal\n";
print !$@ && $object_subset && $object_scalar == 2
    ? "ok 55 - ObjectVal rejects non-references\n"
    : "not ok 55 - ObjectVal rejects non-references\n";

my ($ordinary_ref, $ordinary_scalar, $ordinary_object, $ordinary_subject);
my $ordinary_functions = eval q{
    use feature 'case_match';
    sub RefVal    { 'ordinary ref function' }
    sub ScalarVal { 'ordinary scalar function' }
    sub ObjectVal { 'ordinary object function' }
    $ordinary_ref = RefVal();
    $ordinary_scalar = ScalarVal();
    $ordinary_object = ObjectVal();
    case (RefVal()) {
        match ('ordinary ref function') { $ordinary_subject = 1 }
    }
    1;
};
print !$@ && $ordinary_functions
    && $ordinary_ref eq 'ordinary ref function'
    && $ordinary_scalar eq 'ordinary scalar function'
    && $ordinary_object eq 'ordinary object function'
    && $ordinary_subject
    ? "ok 56 - criteria names remain ordinary functions outside patterns\n"
    : "not ok 56 - criteria names remain ordinary functions outside patterns\n";
print !$@ && $ordinary_functions && $ordinary_subject
    ? "ok 57 - criteria names remain ordinary in a case subject\n"
    : "not ok 57 - criteria names remain ordinary in a case subject\n";

my ($pin_left, $pin_right);
my $multiple_with_aliases = eval q{
    use feature 'case_match';
    case ([1, 2]) with (1 as $pin_left, 2 as $pin_right) {
        match ([$pin_left, $pin_right]) { 1 }
    }
};
print !$@ && $multiple_with_aliases
    ? "ok 58 - with accepts multiple aliased pins\n"
    : "not ok 58 - with accepts multiple aliased pins\n";

my ($header_subject, $header_pin);
my $case_as_without_namespaces = eval q{
    use feature 'case_match';
    my $value = 7;
    case ($value as $header_subject) with (7 as $header_pin) {
        match (7) { $header_subject == 7 && $header_pin == 7 }
    }
};
print !$@ && $case_as_without_namespaces
    ? "ok 59 - case and with as do not require namespaces\n"
    : "not ok 59 - case and with as do not require namespaces\n";

my ($slurp_result, $slurp_min_result, $slurp_min_miss);
my $array_slurps = eval q{
    use feature 'case_match';
    case ([1, 2, 3, 4]) {
        match ([1, @rest]) { $slurp_result = join(',', @rest) }
    }
    case ([1, 2, 3, 4]) {
        match ([1, @rest:3]) { $slurp_min_result = join(',', @rest) }
        match (_) { $slurp_min_result = 'miss' }
    }
    case ([1, 2, 3]) {
        match ([1, @rest:3]) { $slurp_min_miss = 0 }
        match (_) { $slurp_min_miss = 1 }
    }
    1;
};
print !$@ && $array_slurps && $slurp_result eq '2,3,4'
    ? "ok 60 - array slurp captures the remaining elements\n"
    : "not ok 60 - array slurp captures the remaining elements\n";
print !$@ && $array_slurps && $slurp_min_result eq '2,3,4'
    && $slurp_min_miss
    ? "ok 61 - array slurp supports a minimum length\n"
    : "not ok 61 - array slurp supports a minimum length\n";

my ($ref_seen, $scalar_seen, $object_seen);
my $typed_pattern_targets = eval q{
    use feature 'case_match';
    my $ref = [1];
    my $object = bless {}, 'CaseMatch::Object';
    case ($ref) {
        match (RefVal($ref_target)) { $ref_seen = $ref_target->[0] }
    }
    case ('value') {
        match (ScalarVal($scalar_target)) { $scalar_seen = $scalar_target }
    }
    case ($object) {
        match (ObjectVal($object_target)) { $object_seen = ref($object_target) }
    }
    1;
};
print !$@ && $typed_pattern_targets
    && $ref_seen == 1
    && $scalar_seen eq 'value'
    && $object_seen eq 'CaseMatch::Object'
    ? "ok 62 - typed patterns bind their targets\n"
    : "not ok 62 - typed patterns bind their targets\n";

my $typed_pattern_pin_error = eval q{
    use feature 'case_match';
    my $ref = [];
    case ($ref) with ($ref) {
        match (RefVal($ref)) { 1 }
    }
    1;
};
print $@ =~ /typed pattern target cannot be pinned/
    ? "ok 63 - typed pattern targets reject pins\n"
    : "not ok 63 - typed pattern targets reject pins\n";

my $typed_pattern_wrong_target = eval q{
    use feature 'case_match';
    case ({}) {
        match (RefVal(1)) { 1 }
    }
    1;
};
print $@ ? "ok 64 - typed patterns require scalar targets\n"
         : "not ok 64 - typed patterns require scalar targets\n";

my $typed_pattern_empty = eval q{
    use feature 'case_match';
    case ([]) {
        match ([RefVal()]) { 1 }
    }
    1;
};
print !$@ && $typed_pattern_empty
    ? "ok 65 - typed criteria remain usable without targets\n"
    : "not ok 65 - typed criteria remain usable without targets\n";

my ($scalar_ref_value, $nested_ref_value);
my $reference_shapes = eval q{
    use feature 'case_match';
    my $scalar = 7;
    my $scalar_ref = \$scalar;
    my $nested_ref = \\$scalar;
    case ($scalar_ref) {
        match (\$captured) { $scalar_ref_value = $captured }
    }
    case ($nested_ref) {
        match (\\$nested_captured) { $nested_ref_value = $nested_captured }
    }
    1;
};
print !$@ && $reference_shapes && $scalar_ref_value == 7
    && $nested_ref_value == 7
    ? "ok 66 - scalar and nested reference shapes bind referents\n"
    : "not ok 66 - scalar and nested reference shapes bind referents\n";

my $reference_mismatch = eval q{
    use feature 'case_match';
    case ([ 7 ]) {
        match (\$captured) { 1 }
    }
};
print !$@ && !defined($reference_mismatch)
    ? "ok 67 - reference shapes reject non-references\n"
    : "not ok 67 - reference shapes reject non-references\n";

my $reference_pinned = eval q{
    use feature 'case_match';
    my $expected = 7;
    my $actual = \$expected;
    case ($actual) with ($expected) {
        match (\$expected) { 1 }
    }
};
print !$@ && $reference_pinned
    ? "ok 68 - reference shapes compare pinned referents\n"
    : "not ok 68 - reference shapes compare pinned referents\n";
