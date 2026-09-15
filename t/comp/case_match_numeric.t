#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use strict;
use warnings;

# Keep this helper deliberately small.  The values are supplied through the
# lexical pad, so the cases exercise the flags and provenance of the actual
# scalar rather than a freshly parsed constant in the generated source.
sub criterion_matches {
    my ($value, $criterion) = @_;
    my $result = eval qq{
        use feature 'case_match';
        case (\$value) {
            match ($criterion) { 1 }
            match (_)          { 0 }
        }
    };
    die $@ if $@;
    return $result;
}

my $native_iv = 42;
my $native_nv = 42.5;
my $native_integral_nv = 42.0;
my $string_int = '42';
my $string_float = '42.5';
my $string_exponent = '1e3';
my $string_numified = '42';
my $string_exponent_numified = '1e3';
my $number_stringified = 42;
my $ignored_string = "$number_stringified";
my $numeric_copy = 0 + $string_numified;
my $exponent_numeric_copy = 0 + $string_exponent_numified;

my @criteria = qw(Int() Float() Num() IntStr() FloatStr() NumStr());
my @subjects = (
    [ native_iv              => $native_iv,                '101101' ],
    [ native_nv              => $native_nv,                '011011' ],
    [ integral_native_nv     => $native_integral_nv,       '011011' ],
    [ string_integer         => $string_int,               '000101' ],
    [ string_float           => $string_float,             '000011' ],
    [ string_exponent        => $string_exponent,          '000011' ],
    [ string_upper_exponent  => '1E3',                     '000011' ],
    [ string_signed_exponent => '-1.25e+3',                '000011' ],
    [ string_small_exponent  => '2.5E-4',                  '000011' ],
    [ string_plus_integer    => '+1',                      '000101' ],
    [ string_plus_exponent   => '+1E5',                    '000011' ],
    [ string_plus_float_exp  => '+1.1E1',                  '000011' ],
    [ string_leading_dot     => '.5',                      '000011' ],
    [ string_trailing_dot    => '5.',                      '000011' ],
    [ string_numified        => $string_numified,           '000101' ],
    [ exponent_numified      => $string_exponent_numified, '000011' ],
    [ number_stringified     => $number_stringified,        '101101' ],
    [ string_from_number     => $ignored_string,            '000101' ],
    [ zero_string            => '0',                       '000101' ],
    [ zero_float_string      => '0.0',                     '000011' ],
    [ padded_integer_string  => '0000',                    '000101' ],
    [ padded_float_string    => '0000.0',                  '000011' ],
    [ whitespace_integer     => ' 42 ',                    '000101' ],
    [ whitespace_float       => ' 42.5 ',                  '000011' ],
    [ leading_space_integer  => '  +1',                     '000101' ],
    [ trailing_space_integer => '+1  ',                     '000101' ],
    [ both_space_integer     => '  +1  ',                   '000101' ],
    [ leading_space_exponent => '  +1E5',                   '000011' ],
    [ trailing_space_exponent => '+1E5  ',                 '000011' ],
    [ both_space_float_exp   => '  +1.1E1  ',               '000011' ],
    [ malformed_numeric      => '42xyz',                   '000000' ],
    [ nonnumeric             => 'A',                       '000000' ],
    [ empty_string           => '',                         '000000' ],
    [ undefined              => undef,                     '000000' ],
);

my @strict_cases = (
    [ strict_integer         => '42',      'IntStr()',   1 ],
    [ strict_signed_integer  => '+42',     'IntStr()',   1 ],
    [ strict_negative        => '-42',     'IntStr()',   1 ],
    [ strict_plus_exponent   => '+1E5',    'FloatStr()', 1 ],
    [ strict_plus_float_exp  => '+1.1E1',  'FloatStr()', 1 ],
    [ strict_padded_integer  => '042',     'IntStr()',   0 ],
    [ strict_space_integer   => ' 42 ',    'IntStr()',   0 ],
    [ strict_leading_space   => ' +1',      'IntStr()',   0 ],
    [ strict_trailing_space  => '+1 ',      'IntStr()',   0 ],
    [ strict_both_spaces     => ' +1 ',     'IntStr()',   0 ],
    [ strict_float            => '0.5',    'FloatStr()', 1 ],
    [ strict_exponent         => '1e3',    'FloatStr()', 1 ],
    [ strict_zero_float       => '0.0',    'FloatStr()', 1 ],
    [ strict_padded_float     => '0000.0', 'FloatStr()', 0 ],
    [ strict_space_float      => ' 0.5 ',  'FloatStr()', 0 ],
    [ strict_exp_leading_space => ' +1E5',  'FloatStr()', 0 ],
    [ strict_exp_trailing_space => '+1E5 ', 'FloatStr()', 0 ],
    [ strict_zero_integer     => '0',      'NumStr()',   1 ],
    [ strict_padded_zero      => '0000',   'NumStr()',   0 ],
    [ strict_float_num         => '0.0',    'NumStr()',   1 ],
    [ strict_padded_float_num  => '0000.0', 'NumStr()',   0 ],
);

my @num_eq_cases = (
    [ native_zero             => 0,         1 ],
    [ native_float_zero       => 0.0,       1 ],
    [ string_zero             => '0',       1 ],
    [ string_padded_zero      => '0000',    1 ],
    [ string_float_zero       => '0.0',     1 ],
    [ string_padded_float_zero => '0000.0', 1 ],
    [ string_nonzero           => '42',      0 ],
    [ string_fraction          => '0.5',     0 ],
    [ undef_value              => undef,     1 ],
);

plan tests => 8 + @subjects + @strict_cases + 2 + @num_eq_cases + 2;

ok(criterion_matches($native_iv, '42'),
   'a numeric literal matches a native integer');
ok(criterion_matches($native_integral_nv, '42'),
   'a numeric literal matches an equal native floating value');
ok(!criterion_matches($string_int, '42'),
   'a numeric literal does not stringify a string subject');
ok(criterion_matches($string_int, q{"42"}),
   'a string literal matches a string subject');
ok(!criterion_matches($native_iv, q{"42"}),
   'a string literal does not stringify a native integer');
ok(criterion_matches($native_nv, 'Float()'),
   'Float accepts a native non-integral NV');
ok(!criterion_matches($native_integral_nv, 'Int()'),
   'an integral NV is not an IV');
ok(!criterion_matches($native_integral_nv, 'IntStr()'),
   'IntStr does not classify an NV by its displayed spelling');

for my $subject (@subjects) {
    my ($name, $value, $expected) = @$subject;
    my @actual = map criterion_matches($value, $_) ? 1 : 0, @criteria;
    is(join('', @actual), $expected, "$name preserves scalar numeric provenance");
}

for my $case (@strict_cases) {
    my ($name, $value, $criterion, $expected) = @$case;
    is(criterion_matches($value, "Strict($criterion)") ? 1 : 0,
       $expected, "$name under Strict");
}

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    is(criterion_matches('A', 'NumEq(0)'), 1,
       'NumEq follows Perl numeric equality for a nonnumeric string');
}
ok(@warnings == 1 && $warnings[0] =~ /numeric/,
   'NumEq preserves the ordinary numeric warning');

{
    local $SIG{__WARN__} = sub { };
    for my $case (@num_eq_cases) {
        my ($name, $value, $expected) = @$case;
        is(criterion_matches($value, 'NumEq(0)') ? 1 : 0,
           $expected, "$name under NumEq(0)");
    }
}

my $strict_error = eval q{
    use feature 'case_match';
    case (1) { match (Strict(Num())) { 1 } }
};
ok($@ =~ /Strict\(\).*only valid with IntStr\(\), FloatStr\(\), NumStr\(\), or NumEq\(\)/,
   'Strict rejects the native-only Num criterion');

my $target_error = eval q{
    use feature 'case_match';
    case (1) { match (NumEq($value)) { 1 } }
};
ok($@ =~ /NumEq\(\) requires a literal argument/,
   'NumEq rejects a dynamic or destructuring argument');
