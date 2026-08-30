# AI Perl differences from mainline Perl

This document summarizes the intentional and material differences between
the current AI Perl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

Comparison baseline: `origin/blead` at `65d0414b44c1b3c1f1879069332ed7c5b85e00e4`.

At the time of this update, the branch is 77 commits ahead of that baseline,
with 618 changed paths, 38,679 additions, and 3,223 deletions. The changes
include generated files, tests, bundled distributions, documentation, and
development tooling in addition to the runtime changes described below.

## Language and runtime features

### Generators and resumable execution

The fork contains an experimental generator implementation with:

- `use feature 'generator'`;
- `generator_create` blocks;
- explicit `generator_yield` operations;
- `generator_exhausted` state inspection;
- parameterized generator calls, including values sent back into a suspended
  yield;
- list-valued yields and scalar-context handling;
- one-shot continuation ownership and invalid-resume diagnostics;
- exception, cleanup, destruction, GC, callback-context, and re-entrancy
  handling;
- opcode-boundary suspension and resumption through saved Perl process state.

The implementation also includes an execution-context indirection layer. The
process-local interpreter state needed for switching is represented through a
swappable context record, so a context switch can replace a pointer rather
than copy each individual `PL_*` value. Threaded and unthreaded initialization,
exports, generated access macros, and lifecycle handling were updated for this
model.

### Lexical namespaces

An experimental `namespaces` feature adds lexical namespace state, namespace
declarations, `__NAMESPACE__`, namespace aliases, namespace-qualified symbol
resolution, and explicit `CORE:::` boundaries. The parser, keyword tables,
diagnostics, deparser tests, generated headers, and documentation were
updated. `CORE` receives special handling because it is the implementation
namespace for Perl's builtins and operators.

### Classes and roles

The branch includes substantial class and role work, including:

- role composition and conflict handling;
- role fields and required methods;
- transitive role metadata;
- the experimental `implements` spelling and related class behavior;
- `package_implements` support in `builtin`;
- `DOES` delegation through the new role-membership machinery;
- shallow class-object/hash conversion APIs;
- cloning of role metadata in threaded stashes;
- corresponding parser, opcode, diagnostics, documentation, and tests.

### Class objects and Data::Dumper

`Data::Dumper` now understands the new class-object representation through
class-object/hash conversion APIs. The XS and pure-Perl Data::Dumper paths
were updated in `dist/Data-Dumper`, with compatibility guards for building
the distribution on older Perl versions. The class-object support is
documented and tested.

## Bundled distribution changes

### Cpanel::JSON::XS

`Cpanel::JSON::XS` was added as a bundled core distribution, including its XS
implementation, Perl support files, command-line utility, test suite, JSON
specification fixtures, extended tests, metadata, and core maintainer/build
integration.

### Tensor-XS and p5-matrix-utils

The p5-matrix-utils code was imported and developed as the bundled
`Tensor-XS` distribution. It includes Perl `Tensor`, `Matrix`, `Vector`, and
related classes backed by XS storage, together with extensive tests and
examples.

The native tensor work includes:

- descriptor-driven, extensible numeric data types;
- integer and floating-point storage planning;
- coordinate-based indexing;
- conventional row-major strides;
- precomputed element counts;
- flat and nested data loading;
- native tensor blob headers, alignment, and trailing sentinels;
- bulk operations and native access bridges;
- build metadata and core extension integration.

The tensor distribution remains an active experimental area and should not be
read as a finalized numerical-computing ABI.

## Test and development workflow

The branch adds or changes substantial test coverage for generators, classes,
roles, namespaces, tensors, Data::Dumper, and Cpanel::JSON::XS. It also adds
test-harness behavior for saved timing data, including a very high default
weight for files without timing information so new tests are scheduled early.

Agent-oriented repository guidance and subsystem skills were added under
`.agent/`, with related root instructions. Development plans are kept under
`planning/` and excluded from generated distribution manifests while remaining
tracked source files.

Several tests were adjusted for root-directory execution, generated-file
checks, experimental warning handling, and bundled-distribution layout.

## Generated and platform integration

Because the branch changes keywords, features, opcodes, embedding declarations,
interpreter variables, parser grammar, warnings, and bundled distributions,
the comparison includes regenerated parser and header artifacts. Build and
platform integration changes appear in `Configure`, `Makefile.SH`, `Cross/`,
`win32/`, `plan9/`, generated keyword/opcode files, and generated POD indexes.

These generated changes are consequences of the source changes above and must
be regenerated when the relevant inputs change.

## Compatibility posture

Most existing Perl behavior is intentionally preserved where practical, and
the branch contains compatibility fixes for feature-disabled code, `CORE`
handling, threaded builds, and bundled distributions. Nevertheless, the
features listed here are experimental and the project explicitly permits
incompatible changes when they are judged necessary for the fork's goals.
