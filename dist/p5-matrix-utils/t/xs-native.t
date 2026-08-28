#!./perl
use strict;
use warnings;
use Test::More;

my @lib = -d '../dist/p5-matrix-utils/blib/arch'
    ? ('../dist/p5-matrix-utils/blib/lib', '../dist/p5-matrix-utils/blib/arch')
    : ('dist/p5-matrix-utils/blib/lib', 'dist/p5-matrix-utils/blib/arch');
unshift @INC, @lib;

eval { require Tensor::XS; 1 }
    or plan skip_all => "Tensor::XS is not built: $@";

my $tensor = Tensor::XS->new([2, 3], [1, 2, 3, 4, 5, 6]);
is $tensor->rank, 2, 'native rank is stored';
is $tensor->size, 6, 'native size is stored';
is_deeply $tensor->shape, [2, 3], 'native shape metadata is returned';
is $tensor->at(4), 5, 'native element access works';
is_deeply $tensor->data, [1, 2, 3, 4, 5, 6],
    'native data is returned in row-major order';

done_testing;
