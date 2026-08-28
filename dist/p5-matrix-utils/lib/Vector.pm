
use v5.40;
use experimental qw[ class ];

use Carp;

use Tensor;

class Vector :isa(Tensor) {
    # --------------------------------------------------------------------------
    # Vector specific methods
    # --------------------------------------------------------------------------

    method index_of ($value) {
        my $i = 0;
        while ($i < $self->size) {
            return $i if $self->at( $i ) == $value;
            $i++;
        }
        return -1;
    }

    # --------------------------------------------------------------------------
    # Static Constructors
    # --------------------------------------------------------------------------

    sub concat ($class, $a, $b) {
        return $class->initialize(($a->size + $b->size), [ $a->to_list, $b->to_list ])
    }

    # --------------------------------------------------------------------------
    # Matrix multiplication
    # --------------------------------------------------------------------------

    method matrix_multiply ($other) {
        # OPTIMIZED: Direct array manipulation
        # Vector (n) × Matrix (n×p) = Vector (p)
        my $n = $self->size;
        my $p = $other->cols;

        my $vec_data = $self->data;
        my $mat_data = $other->data;

        my @result;

        # For each output element (column in matrix)
        for (my $j = 0; $j < $p; $j++) {
            my $sum = 0;
            # Dot product of vector with column j of matrix
            for (my $i = 0; $i < $n; $i++) {
                # Matrix is row-major: M[i,j] = mat_data[i * p + j]
                $sum += $vec_data->[$i] * $mat_data->[$i * $p + $j];
            }
            push @result, $sum;
        }

        return Vector->initialize($p, \@result);
    }

    # --------------------------------------------------------------------------
    # Reductions (scalar results)
    # --------------------------------------------------------------------------

    method min_value { $self->reduce_data_array(\&Tensor::Ops::min) }
    method max_value { $self->reduce_data_array(\&Tensor::Ops::max) }

    method dot_product ($other) {
        my $i = 0;
        return $self->reduce_data_array(sub ($acc, $x) { $acc + ($x * $other->at($i++)) }, 0)
    }

    # --------------------------------------------------------------------------

    method to_string (@) { return '<' . (join ' ' => $self->to_list) . '>' }
}
