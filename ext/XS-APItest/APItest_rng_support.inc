static const char rng_test_no_clone = 0;

static NV
rng_test_quarter(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(referent);
    PERL_UNUSED_ARG(fast);
    return 0.25;
}

static NV
rng_test_three_quarters(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(referent);
    PERL_UNUSED_ARG(fast);
    return 0.75;
}

static bool
rng_test_validate(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(fast);
    return SvIOK(referent) && SvIVX(referent) != 0;
}
