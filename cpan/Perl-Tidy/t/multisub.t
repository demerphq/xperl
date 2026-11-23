use strict;
use warnings;
use Test::More;
use Perl::Tidy;

sub format_source {
    my ($source) = @_;
    my ( $output, $errors, $stderr ) = ( '', '', '' );
    my $status = Perl::Tidy::perltidy(
        source      => \$source,
        destination => \$output,
        errorfile   => \$errors,
        stderr      => \$stderr,
        argv        => '-npro',
    );
    return ( $status, $output, $errors, $stderr );
}

my $fib = <<'SOURCE';
multi sub fib(0) {return 0}
multi sub fib(1) {return 1}
multi sub fib($n if $n == int($n)) {return fib($n-1)+fib($n-2)}
SOURCE
my $expected = <<'EXPECTED';
multi sub fib(0)                     { return 0 }
multi sub fib(1)                     { return 1 }
multi sub fib( $n if $n == int($n) ) { return fib( $n - 1 ) + fib( $n - 2 ) }
EXPECTED

my @cases = (
    [ 'recursive literal and guarded clauses', $fib, $expected ],
    [ 'empty head', 'multi sub empty() { 0 } empty(1);' ],
    [ 'literal heads', 'multi sub f(0) { 0 } multi sub f(1) { 1 } f(2);' ],
    [ 'nested patterns', <<'SOURCE' ],
multi sub shape([$first, @rest], {x => $x, ...} if $x > 0) {
    return [$first, $x, @rest];
}
SOURCE
    [ 'pins and regexes', <<'SOURCE' ],
multi sub select(^$pin, /a(b)/ if valid($pin)) { return $pin }
SOURCE
    [ 'multiline declarations', <<'SOURCE' ],
multi # declaration prefix
sub # declaration kind
split_head # name
(0) { 0 }
multi sub split_head
($n if $n > 0) { split_head(0) }
SOURCE
    [ 'methods', <<'SOURCE' ],
class Example {
    multi method value(0) { 0 }
    multi method value($n if $n > 0) { $self->value(0) }
}
SOURCE
    [ 'multiline methods', <<'SOURCE' ],
class Example {
    multi
    method
    value
    () { 0 }
    multi method value($n if $n > 0) { $self->value() }
}
SOURCE
);

for my $case (@cases) {
    my ( $name, $source, $want ) = @$case;
    my ( $status, $output, $errors, $stderr ) = format_source($source);
    is( $status, 0, "$name accepted" );
    is( $errors, '', "$name has no parsing diagnostics" );
    is( $stderr, '', "$name has no stderr" );
    is( $output, $want, "$name formatting" ) if defined $want;

    my ( $again_status, $again, $again_errors ) = format_source($output);
    is( $again_status, 0, "$name formatted output accepted" );
    is( $again_errors, '', "$name formatted output has no diagnostics" );
    is( $again, $output, "$name formatting is stable" );
}

# These calls follow multi declarations in the same formatter process.
# Declaration recognition must not turn an ordinary use of multi into syntax.
my $calls = 'multi($x); $object->multi($x); my %h = (multi => 1);';
my ( $call_status, $call_output, $call_errors ) = format_source($calls);
is( $call_status, 0, 'ordinary uses of multi accepted' );
is( $call_errors, '', 'ordinary uses of multi have no diagnostics' );
like( $call_output, qr/multi\(\$x\)/, 'ordinary call retains function spacing' );

my ( $duplicate_status, undef, $duplicate_errors ) =
  format_source('sub ordinary { 1 } sub ordinary { 2 }');
is( $duplicate_status, 2, 'ordinary duplicate definitions still reported' );
like( $duplicate_errors, qr/already saw definition/, 'duplicate diagnostic retained' );

my ( $guard_status, undef, $guard_errors ) =
  format_source('sub ordinary($n if $n > 0) { $n }');
is( $guard_status, 2, 'guard in an ordinary signature still reported' );
like( $guard_errors, qr/found 'if' in non-block/, 'ordinary guard diagnostic retained' );

done_testing();
