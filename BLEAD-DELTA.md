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
with 620 changed paths, 39,076 additions, and 3,223 deletions. The changes
include generated files, tests, bundled distributions, documentation, and
development tooling in addition to the runtime changes described below.

## Language and runtime features

### Generators and resumable execution

The fork contains an experimental generator implementation with:

- `use feature 'generator'`;
- `gen` blocks, the generator equivalent of `sub`;
- explicit `yield` operations;
- `generator::running`, `generator::completed`, `generator::failed`, and
  `generator::exhausted` functions, also available as methods on generator
  objects;
- a `use generator` pragma that enables the feature and signatures;
- initial generator arguments through either a normal `@_` body or a
  signature, with `use generator` enabling signatures automatically;
- parameterized generator calls, including values sent back into a suspended
  yield without rebinding the initial signature;
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

Generators are also a small cooperative-concurrency primitive: a caller can
explicitly resume one generator, retain its suspended continuation, and resume
another generator before returning to the first. They do not create threads or
provide implicit scheduling; any interleaving is controlled by the code that
resumes the generators. The continuation is delimited by the generator body
and is one-shot, while the saved process state preserves the Perl execution
context across each suspension.

Related POD: [`pod/perlgenerator.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlgenerator.pod) and [`lib/generator.pm`](https://github.com/demerphq/perl5/blob/ai-perl/lib/generator.pm) describe the combined pragma and generator interface; [`lib/builtin.pm`](https://github.com/demerphq/perl5/blob/ai-perl/lib/builtin.pm) documents builtin import behavior.  The dedicated POD covers generators,
continuations, and cooperative resumable execution. [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlexperiment.pod),
[`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlfunc.pod), [`pod/perlsyn.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlsyn.pod), [`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldiag.pod), and
[`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) cover the experimental status, keywords, syntax,
diagnostics, and release notes.

### Lexical namespaces

An experimental `namespaces` feature adds lexical namespace state, namespace
declarations, `__NAMESPACE__`, namespace aliases, namespace-qualified symbol
resolution, and explicit `CORE:::` boundaries. The parser, keyword tables,
diagnostics, deparser tests, generated headers, and documentation were
updated. `CORE` receives special handling because it is the implementation
namespace for Perl's builtins and operators.

Related POD: [`pod/perlnamespace.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlnamespace.pod) is the dedicated namespace reference;
[`pod/perlsyn.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlsyn.pod), [`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlfunc.pod), [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlexperiment.pod),
[`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldiag.pod), and [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) cover syntax, builtins,
experimental status, diagnostics, and release notes.

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

Related POD: [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlclass.pod) is the primary class and role reference;
[`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlfunc.pod), [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlexperiment.pod), [`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldiag.pod), and
[`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) cover the builtins, experimental status, diagnostics, and
release notes.

### Class objects and Data::Dumper

`Data::Dumper` now understands the new class-object representation through
class-object/hash conversion APIs. The XS and pure-Perl Data::Dumper paths
were updated in [`dist/Data-Dumper`](https://github.com/demerphq/perl5/tree/ai-perl/dist/Data-Dumper/), with compatibility guards for building
the distribution on older Perl versions. The class-object support is
documented and tested.

Related POD: [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlclass.pod), [`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlfunc.pod), and [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod)
describe the class-object APIs and their user-visible integration.
Distribution-specific history is in [`dist/Data-Dumper/Changes`](https://github.com/demerphq/perl5/blob/ai-perl/dist/Data-Dumper/Changes); no separate
Data::Dumper POD document was added for this change.

## Bundled distribution changes

### Cpanel::JSON::XS

`Cpanel::JSON::XS` was added as a bundled core distribution, including its XS
implementation, Perl support files, command-line utility, test suite, JSON
specification fixtures, extended tests, metadata, and core maintainer/build
integration.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) records the bundled-core change. The imported
distribution's API and tests remain documented in its own source and test
files; no separate core POD document was added for Cpanel::JSON::XS.

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

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) records the bundled distribution change.
Tensor-specific design and status are documented in
[`dist/Tensor-XS/Changes`](https://github.com/demerphq/perl5/blob/ai-perl/dist/Tensor-XS/Changes), [`dist/Tensor-XS/XS_DESIGN.md`](https://github.com/demerphq/perl5/blob/ai-perl/dist/Tensor-XS/XS_DESIGN.md),
[`dist/Tensor-XS/NOTES.md`](https://github.com/demerphq/perl5/blob/ai-perl/dist/Tensor-XS/NOTES.md), and the other design and result Markdown files in
that distribution; no dedicated core POD document was added.

## Test and development workflow

The branch adds or changes substantial test coverage for generators, classes,
roles, namespaces, tensors, Data::Dumper, and Cpanel::JSON::XS. It also adds
test-harness behavior for saved timing data, including a very high default
weight for files without timing information so new tests are scheduled early.

Agent-oriented repository guidance and subsystem skills were added under
[`.agent/`](https://github.com/demerphq/perl5/tree/ai-perl/.agent/), with related
root instructions. Development plans are kept under
[`planning/`](https://github.com/demerphq/perl5/tree/ai-perl/planning/) and
excluded from generated distribution manifests while remaining tracked source
files.

Several tests were adjusted for root-directory execution, generated-file
checks, experimental warning handling, and bundled-distribution layout.

Related POD: no dedicated POD document was added for the test-harness and
agent-workflow changes. Their operational documentation is in
[`AGENTS.md`](https://github.com/demerphq/perl5/blob/ai-perl/AGENTS.md),
[`.agent/skills/`](https://github.com/demerphq/perl5/tree/ai-perl/.agent/skills/), and the tracked materials under
[`planning/`](https://github.com/demerphq/perl5/tree/ai-perl/planning/).

## Generated and platform integration

Because the branch changes keywords, features, opcodes, embedding declarations,
interpreter variables, parser grammar, warnings, and bundled distributions,
the comparison includes regenerated parser and header artifacts. Build and
platform integration changes appear in
[`Configure`](https://github.com/demerphq/perl5/blob/ai-perl/Configure),
[`Makefile.SH`](https://github.com/demerphq/perl5/blob/ai-perl/Makefile.SH),
[`Cross/`](https://github.com/demerphq/perl5/tree/ai-perl/Cross/),
[`win32/`](https://github.com/demerphq/perl5/tree/ai-perl/win32/),
[`plan9/`](https://github.com/demerphq/perl5/tree/ai-perl/plan9/), generated keyword/opcode files, and generated POD indexes.

These generated changes are consequences of the source changes above and must
be regenerated when the relevant inputs change.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) records user-visible consequences; no
separate POD document was added for the generated-file and platform
integration details.

## Compatibility posture

Most existing Perl behavior is intentionally preserved where practical, and
the branch contains compatibility fixes for feature-disabled code, `CORE`
handling, threaded builds, and bundled distributions. Nevertheless, the
features listed here are experimental and the project explicitly permits
incompatible changes when they are judged necessary for the fork's goals.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perldelta.pod) records notable user-visible differences,
while [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlexperiment.pod), [`pod/perlgenerator.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlgenerator.pod), [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlclass.pod), and
[`pod/perlnamespace.pod`](https://github.com/demerphq/perl5/blob/ai-perl/pod/perlnamespace.pod) document the experimental features themselves.
