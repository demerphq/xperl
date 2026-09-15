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

The experimental `iterator` package generalizes the callable lifecycle
protocol to ordinary blessed code references. It distinguishes an ordinary
empty return value from completion and exposes running, completed, failed,
and derived exhausted states; generator continuation states remain private to
the generator runtime.

An uncaught exception escaping an iterator body is rethrown without silently
changing its state. The iterator contract requires code presenting itself as
an iterator to report completion accurately, so `exhausted` remains reliable
when an empty list is a valid ordinary result. The protocol also defines
`restartable` and `restart`; iterators are non-restartable by default and the
default restart method reports that restarting is unsupported.

The iterator API is documented in `pod/perliterator.pod` and `lib/iterator.pm`
and is covered by `t/op/iterator.t`.

### Class objects and Data::Dumper

Class objects now understand shallow class-object/hash conversion APIs for
serializer support. `Data::Dumper` uses the new representation in both its XS
and pure-Perl paths, with compatibility guards for building the distribution
on older Perl versions. The class-object support is documented and tested.

The relevant APIs and integration are described in `pod/perlclass.pod` and
the class-object and Data::Dumper tests cover the conversion behavior.

### Classes and roles

The class system now supports reusable `role` declarations and algebraic role
composition. Roles can provide fields, methods, field initializers, required
methods, and `ADJUST` blocks. A class or another role consumes one or more
roles with the experimental `:implements` attribute.

Roles compose transitively, and a shared role reached through a diamond is
included once. Unresolved method conflicts between unrelated roles and
conflicting fields are reported at composition time. The `implements` method
and infix operator provide nominal membership tests, including roles composed
by a superclass; this is distinct from `isa`, while `DOES` reports composed
roles as well as ordinary inheritance relationships.

A minimal example is:

```perl
use feature 'class';

role Named {
    method name() { "a named object" }
}

class Person :implements(Named) {
    field $name :param;
    method name() { $name }
}
```

The class and role behavior, conflict handling, field composition, required
methods, implementation membership, parser support, diagnostics, and threaded
metadata are documented in `pod/perlclass.pod` and covered by the role tests.

## Bundled distribution changes

### Tensor-XS and p5-matrix-utils

The p5-matrix-utils code is imported and developed as the bundled experimental
`Tensor-XS` distribution. It includes Perl `Tensor`, `Matrix`, `Vector`, and
related classes backed by XS storage, together with extensive tests and
examples.

The native tensor work includes descriptor-driven numeric data types,
integer and floating-point storage, coordinate-based indexing, row-major
strides, precomputed element counts, flat and nested data loading, native
tensor blob headers with alignment and trailing sentinels, bulk operations,
native access bridges, and core build integration. The public Perl classes
retain their interfaces while values use contiguous typed native buffers.

The distribution remains an experimental area rather than a finalized
numerical-computing ABI. Design and status details are recorded in
`dist/Tensor-XS/Changes`, `dist/Tensor-XS/XS_DESIGN.md`, and the related
distribution notes and result documents.

### Cpanel::JSON::XS

`Cpanel::JSON::XS` is added as a bundled core distribution, including its XS
implementation, Perl support files, command-line utility, test suite, JSON
specification fixtures, extended tests, metadata, and core maintainer/build
integration.

The imported distribution's API and tests remain documented in its own source
and test files. Its core integration is covered by the dual-life and build
checks.

### Lexical namespaces

The experimental `namespaces` feature adds lexical namespace state,
`namespace` declarations, `__NAMESPACE__`, namespace aliases,
namespace-qualified symbol resolution, and explicit `CORE:::` boundaries.
The parser, keyword tables, diagnostics, deparser tests, generated headers,
and documentation were updated. `CORE` receives special handling because it
is the implementation namespace for Perl's builtins and operators.

For example:

```perl
use feature 'namespaces';

namespace MyApp;
package Model;

sub name { "model" }
```

Here `Model` means `MyApp::Model` while this code is compiled. The namespace
prefix is lexical and does not replace Perl's ordinary current package. An
explicit `:::` boundary resolves a name from the top level instead.

The behavior is documented in `pod/perlnamespace.pod`, with related syntax,
builtin, experimental-status, diagnostic, and release documentation updated.
The namespace and bootstrap tests cover the implementation.

### Case/match data-shape matching

The experimental `case_match` feature adds a conditional construct for values
whose shape matters. A `case` evaluates one subject and considers ordered
`match` clauses from top to bottom; only the first successful clause runs, and
the outer case body may contain only direct match clauses. A wildcard
`match (_)` is the usual default. Without a successful clause, `case` returns
`undef` in scalar context and an empty list in list context.

The text inside `match (...)` is a data-shape language rather than an ordinary
Perl expression. It supports scalar literals, arrays, hashes, nested shapes,
class-qualified objects, regular-expression criteria, typed numeric criteria,
reference/value criteria, tails, and open shapes. Scalar names introduce
match-local bindings, while `^` and `with` pin existing values. An optional
`if` introduces an unrestricted Perl guard that runs after the shape matches.

Bindings are discarded when a shape or guard fails, but closures may retain
them after the clause ends. Duplicate capture names, unsupported or ambiguous
syntax, invalid regex constructs, impossible slurp combinations, and repeated
constant keys are rejected explicitly rather than silently reinterpreted.
Pins preserve reference identity and undefined-value distinctions; captured
references preserve identity and tail captures do not alias source slots.

Object shapes inspect blessed references structurally without invoking
constructors or arbitrary methods. Native class objects are supported, while
inheritance and role matching remain reserved for future pattern forms. Simple
constant-only cases may use specialized linear, binary-search, or hash
dispatch, but source order and first-match semantics remain unchanged. This
feature is independent of the older `given`/`when` mechanism.

The reference and tutorial are in `pod/perlcasematch.pod` and
`pod/perlcasematchtut.pod`; `pod/perlsyn.pod`, `pod/perldiag.pod`,
`pod/perlexperiment.pod`, and `pod/perldelta.pod` cover syntax, diagnostics,
experimental status, and release notes. Compiler and runtime behavior is
covered by the case-matching tests and the associated planning notes.

## Generated and platform integration

The feature work changes keywords, features, opcodes, embedding declarations,
interpreter variables, parser grammar, warnings, and bundled distributions.
The branch therefore includes regenerated parser and header artifacts,
generated keyword and opcode files, generated POD indexes, and corresponding
build and platform integration. These generated changes are consequences of
the source changes above and must be regenerated when their inputs change.

## Compatibility posture

Existing Perl behavior is preserved where practical. The fork's experimental
features and development policies may continue to evolve as the branch
develops. Compatibility handling includes feature-disabled code paths,
`CORE` behavior, threaded builds, and bundled distributions.
