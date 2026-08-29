
use v5.40;
use experimental qw[ class ];

use Carp;

use Tensor;

class Scalar :isa(Tensor) {
    use overload (
        '0+'   => 'get',
        'bool' => sub ($a, @) { !!($a->get) }
    );

    sub initialize ($class, @args) {
        my ($shape, $value) = @args == 1 ? ([1], $args[0]) : @args;
        return $class->new(shape => $shape, data => $value);
    }

    method rank { 0 }

    method get { $self->data->[0] }

    method to_string { sprintf '(%d)' => $self->get }
}
