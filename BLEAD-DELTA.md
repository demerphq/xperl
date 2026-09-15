# XPerl differences from mainline Perl

This document summarizes the intentional and material differences between
the current XPerl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

## AI policy is now permissive

The branch has removed the restrictive AI policy document and replaced it
with repository guidance, skills, and planning material intended to make
automated development inspectable and collaborative.

## Test and development workflow

The branch updates the test harness so new test files without saved timing
data receive a very high scheduling weight. This keeps newly added tests from
being deferred behind the established test suite during parallel runs.

Repository guidance and planning material are tracked as part of the
development workspace. These changes support maintainers and contributors
without changing ordinary Perl language behavior.

## Random-number generation

The branch adds an extensible byte-based random-number framework built around
the `${^RNG}` provider interface. The bundled `RNG` distribution provides
non-cryptographic providers including PCG, drand48, Wyrand, and Xoshiro, plus
an HMAC-DRBG provider with deterministic and operating-system-seeded modes.

Providers implement the shared `rand_bytes` and `srand` protocol. The core
integration supports provider selection and the XS fast paths needed by the
bundled implementations. HMAC-DRBG is not FIPS validated, and the
non-cryptographic providers are intended for simulation, testing, and similar
uses rather than security-sensitive work.

The distribution documentation is in `dist/RNG/README` and
`dist/RNG/Changes`; the core-facing documentation is in `pod/perlrng.pod`.
Provider behavior is covered by the tests under `dist/RNG/t/`.

## Compatibility posture

Existing Perl behavior is preserved where practical. The fork's experimental
features and development policies may continue to evolve as the branch
develops.
