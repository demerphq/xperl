MODULE = XS::APItest            PACKAGE = XS::APItest

void
rng_fast_register(object, mode = 0)
    SV *object
    UV mode
PREINIT:
    Perl_rng_fast descriptor;
CODE:
    Zero(&descriptor, 1, Perl_rng_fast);
    descriptor.abi = PERL_RNG_FAST_ABI;
    descriptor.size = sizeof(descriptor);
    descriptor.U01 = mode == 1 ? rng_test_three_quarters : rng_test_quarter;
    if (mode == 2)
        descriptor.validate = rng_test_validate;
    if (mode == 3)
        descriptor.abi++;
    if (mode == 4)
        descriptor.size--;
    if (mode == 5)
        descriptor.U01 = NULL;
    if (mode == 6)
        descriptor.state = (void *)&rng_test_no_clone;
    Perl_rng_fast_register(aTHX_ SvROK(object) ? SvRV(object) : object,
                            &descriptor);

void
rng_fast_unregister(object)
    SV *object
CODE:
    Perl_rng_fast_unregister(aTHX_ SvRV(object));

bool
rng_fast_find(object)
    SV *object
CODE:
    RETVAL = Perl_rng_fast_find(aTHX_ SvRV(object)) != NULL;
OUTPUT:
    RETVAL

UV
rng_fast_fake_address(...)
CODE:
    RETVAL = 1;
OUTPUT:
    RETVAL
