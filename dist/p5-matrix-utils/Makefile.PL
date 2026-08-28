use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Tensor::XS',
    VERSION_FROM => 'lib/Tensor/XS.pm',
    PM           => { 'lib/Tensor/XS.pm' => '$(INST_LIBDIR)/XS.pm' },
);
