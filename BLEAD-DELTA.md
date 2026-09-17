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

## Language and runtime features

### Generators and resumable execution

The fork contains an experimental generator implementation with
`use feature 'generator'`, `gen` blocks, and explicit `yield` operations.
Generator objects expose running, completed, failed, and exhausted lifecycle
states through functions and methods. Initial arguments may be supplied through
an ordinary `@_` body or a signature, while later calls can send values back
to a suspended `yield` without rebinding the initial arguments. List-valued
yields and scalar-context handling are preserved.

Generator continuation ownership is one-shot, with diagnostics for invalid
resumption. Exception, cleanup, destruction, garbage collection, callback
context, and re-entry behavior are handled across opcode-boundary suspension
and resumption. The saved process state preserves the Perl execution context
across each suspension.

The active `PL_*` variables retain their direct interpreter or global storage.
Only the marked execution state is copied into a generator process state when
a generator is suspended or resumed. This avoids adding an execution-context
pointer dereference to ordinary calls while still allowing generator stacks
and execution state to be switched safely. Threaded and unthreaded
initialization, exports, generated access macros, and lifecycle handling were
updated for this model.

The members of the threaded context structure were also reordered to keep the
hottest execution fields together, improving ordinary subroutine calls by
several instructions per call.

Generators provide cooperative resumable execution: callers explicitly choose
which suspended generator to resume, and no threads or implicit scheduler are
created. A minimal generator can be written as:

```perl
use generator;

my $letters = gen {
    for my $letter ("A".."E") {
        yield $letter;
    }
};

my $numbers = gen {
    for my $number (1..5) {
        yield $number;
    }
};


for (1..5) {
    say $letters->(), $numbers->(), " ";
}
say "done" if $letters->exhausted;

# Outputs:
# A1 B2 C3 D4 E5 done
```

The interface is documented in `pod/perlgenerator.pod` and `lib/generator.pm`;
related feature, syntax, diagnostic, and release documentation was updated.
The runtime and callable-object behavior is covered by the generator and XS
API runtime tests.

## Compatibility posture

Existing Perl behavior is preserved where practical. The fork's experimental
features and development policies may continue to evolve as the branch
develops.
