# XPerl differences from mainline Perl

This document summarizes the intentional and material differences between
the current XPerl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

Comparison baseline: `origin/blead` at `a57c5954cbfde062678ff826818742f640b1cf60`.

At the time of this update, the branch is 163 commits ahead of that baseline,
with 628 changed paths, 45,412 additions, and 3,195 deletions. The changes
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

The related experimental `iterator` package generalizes the callable
lifecycle protocol to ordinary blessed code references. This lets code use a
closure as an iterator without confusing an ordinary empty return value with
the end of the sequence. It provides
`RUNNING`, `COMPLETED`, and `FAILED` state, with `EXHAUSTED` derived from the
two terminal states; generator continuation states remain private to the
generator runtime. An uncaught exception escaping an iterator body is
rethrown without changing its state; the iterator implementation or caller
may explicitly mark it failed.
The iterator contract requires code presenting itself as an iterator to report
completion accurately, so `exhausted` is reliable even when an empty list is a
valid ordinary result.
The protocol also defines `restartable` and `restart`; the default is
non-restartable, and the default `restart` method reports that restarting is
unsupported.

A small generator can be written and consumed like this:

```perl
use generator;

my $letters = gen {
    yield "A";
    yield "B";
};

say $letters->();
say $letters->();
say "done" if $letters->exhausted;
```

The first two calls produce values.  The third call has observed the end of
the block, so the generator reports that it is exhausted.  A generator can
also receive initial arguments and send values back to a suspended `yield`;
the detailed rules are described in the linked generator manual.

Related POD: [`pod/perlgenerator.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlgenerator.pod) and [`lib/generator.pm`](https://github.com/demerphq/perl5/blob/xperl/main/lib/generator.pm) describe the combined pragma and generator interface; [`pod/perliterator.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perliterator.pod) describes the general callable-iterator protocol; [`lib/iterator.pm`](https://github.com/demerphq/perl5/blob/xperl/main/lib/iterator.pm) documents its package API; and [`lib/builtin.pm`](https://github.com/demerphq/perl5/blob/xperl/main/lib/builtin.pm) documents builtin import behavior.  The dedicated POD covers generators,
continuations, and cooperative resumable execution. [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlexperiment.pod),
[`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlfunc.pod), [`pod/perlsyn.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlsyn.pod), [`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldiag.pod), and
[`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) cover the experimental status, keywords, syntax,
diagnostics, and release notes.

### `-E` enables the XPerl experimental surface

The `-E` command-line switch now enables `feature ':all'` and imports
`builtin ':all'`. This makes the branch's experimental keywords and builtin
functions available directly in one-liners and command-line programs, while
preserving the ordinary `-e` behavior. Experimental functions still retain
their normal experimental warnings.

Related POD: [`pod/perlrun.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlrun.pod) documents `-E`; [`lib/builtin.pm`](https://github.com/demerphq/perl5/blob/xperl/main/lib/builtin.pm) documents the `:all` builtin bundle; [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) records the release-note entry. The command-line regression is in [`t/run/switches.t`](https://github.com/demerphq/perl5/blob/xperl/main/t/run/switches.t).

### Case/match data-shape matching

The experimental `case_match` feature adds a new kind of conditional.  It is
designed for values whose *shape* matters: for example, an array reference
whose first element is the string `"ok"`, followed by a value we want to name.
This is called data-shape matching because it combines two familiar ideas:
checking a structure and taking selected pieces out of it.

The basic form is:

```perl
use feature 'case_match';

case ($value) {
    match ([ "ok", $number ]) { say "received $number" }
    match ([ "error", $message ]) { warn $message }
    match (_) { say "unrecognised value" }
}
```

The `case` expression evaluates one subject.  Its `match` clauses are then
considered from top to bottom, and only the first successful clause runs.  A
clause does not fall through to the next clause.  The body of a clause is an
ordinary Perl block, but the outer `case` body may contain only direct
`match` clauses.  A wildcard written as `match (_)` always succeeds and is the
usual way to write a default clause.  Without a successful clause, `case`
returns `undef` in scalar context and an empty list in list context.

The text inside `match (...)` is a small data-shape language, not an ordinary
Perl expression.  Perl-like punctuation makes arrays, hashes, literals, and
names easy to recognize, but the text describes a shape rather than computing
a value.  A name such as `$number` is a new scalar binding local to the
clause's block.  Bindings are tentative: they become visible only after the
whole data shape and its optional guard succeed.

Scalar shapes include `undef`, literal strings, literal numbers, `true`, and
`false`.  Strings and numbers are deliberately distinct, so `match (1)` and
`match ("1")` express different cases.  Boolean shapes use Perl's normal
truth-value rules.  Regular-expression values can be used as scalar matching
criteria.  Regular-expression shapes update Perl's ordinary capture variables
and make named captures available as clause-local scalar bindings.  For
example, `match (/^user: (?<name>[[:word:]]+)$/) { say $name }` binds `$name`
when the subject matches; a named capture that does not participate is bound
to `undef`.
The special criteria `RefVal()`, `ScalarVal()`, and `ObjectVal()`
test, respectively, for any reference, any non-reference scalar, and a
blessed reference.  They can each take one binding target, such as
`ObjectVal($object)`.

String shapes may contain one unbound scalar inside literal concatenation, for
example `match ("x" . $middle . "z")`.  The name receives the text between the
literal parts.  A name listed by `with` is different: it is a pinned existing
lexical and must match its current value rather than capture new text.

Array and hash shapes can be nested.  An array shape without an ellipsis must
have exactly the listed length.  Edge ellipses describe open shapes, such as
`[ $first, ... ]` or `[ ..., $last ]`; an array can also use a final array
binding such as `[ 1, 2, @rest ]` to capture the remaining tail.  `@rest:N`
requires at least `N` remaining elements, where `N` is currently between 0 and
255.  A hash shape requires its listed keys; a final `...` permits additional
keys.  The current implementation permits one array slurp and does not combine
it with an ellipsis or another slurp.

An optional `if` introduces an ordinary Perl guard.  The guard runs after the
data shape has matched and may use the tentative bindings.  Guards are
unrestricted Perl expressions: they may call functions, have side effects, or
throw exceptions.  A false guard rejects the clause and discards its bindings.

`case` also supports a subject name and pinned values:

```perl
case (read_record() as $record) with ($wanted_type, $wanted_version) {
    match ({ type => $wanted_type, version => $wanted_version, ... }) {
        use_record($record);
    }
}
```

The `as` and `with` forms shown here belong to `case_match`; they do not enable
the separate namespace `as` syntax.  `with` accepts a list of existing scalar
lexicals, and each item may independently use `as` to create a case-local pin.

For a case made entirely from simple constants and no guards, the compiler can
select a specialized dispatch representation.  The current implementations
include linear, binary-search, and hash-based constant lookup.  These are
performance choices, not different language features: source order, the first
successful clause, and default-clause behavior remain the same.

This feature is independent of Perl's older `given`/`when` mechanism.  The two
constructs are alternatives for conditional code, but `case`/`match` has no
fall-through semantics and does not reuse the `given`/`when` execution model.

Related POD: [`pod/perlcasematch.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlcasematch.pod) is the beginner-oriented feature guide.  [`pod/perlsyn.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlsyn.pod) documents the syntax and current semantics, while [`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldiag.pod) documents its diagnostics.  [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlexperiment.pod) and [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) record its experimental status and release notes.

The implementation is tested in [`t/comp/case_match.t`](https://github.com/demerphq/perl5/blob/xperl/main/t/comp/case_match.t) and demonstrated in [`t/comp/case_match_examples.t`](https://github.com/demerphq/perl5/blob/xperl/main/t/comp/case_match_examples.t), with design notes in [`planning/perl-pattern-matching.md`](https://github.com/demerphq/perl5/blob/xperl/main/planning/perl-pattern-matching.md).  Dispatch benchmarks are kept in [`planning/scripts/case_dispatch_compare.pl`](https://github.com/demerphq/perl5/blob/xperl/main/planning/scripts/case_dispatch_compare.pl), [`planning/scripts/case_dispatch_weight.pl`](https://github.com/demerphq/perl5/blob/xperl/main/planning/scripts/case_dispatch_weight.pl), and [`planning/scripts/case_given_compare.pl`](https://github.com/demerphq/perl5/blob/xperl/main/planning/scripts/case_given_compare.pl).

### Lexical namespaces

An experimental `namespaces` feature adds lexical namespace state, namespace
declarations, `__NAMESPACE__`, namespace aliases, namespace-qualified symbol
resolution, and explicit `CORE:::` boundaries. The parser, keyword tables,
diagnostics, deparser tests, generated headers, and documentation were
updated. `CORE` receives special handling because it is the implementation
namespace for Perl's builtins and operators.

For example, a namespace can provide a lexical prefix for package names:

```perl
use feature 'namespaces';

namespace MyApp;
package Model;

sub name { "model" }
```

Here `Model` means `MyApp::Model` while this code is compiled.  The namespace
prefix is lexical and does not replace Perl's ordinary current package.  An
explicit `:::` boundary can be used when a name should be resolved from the
top level instead.

Related POD: [`pod/perlnamespace.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlnamespace.pod) is the dedicated namespace reference;
[`pod/perlsyn.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlsyn.pod), [`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlfunc.pod), [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlexperiment.pod),
[`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldiag.pod), and [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) cover syntax, builtins,
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

A minimal class and role can look like this:

```perl
use feature 'class';

role Named {
    method name() { "a named object" }
}

class Person :implements(Named) {
    field $name :param;
    method name() { $name }
}

say Person->new(name => 'Ada')->name;
```

The class declaration supplies the class structure and constructor, while the
role states an interface that the class implements.  The `implements` spelling
is experimental and belongs to this class-and-role system.

Related POD: [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlclass.pod) is the primary class and role reference;
[`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlfunc.pod), [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlexperiment.pod), [`pod/perldiag.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldiag.pod), and
[`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) cover the builtins, experimental status, diagnostics, and
release notes.

### Class objects and Data::Dumper

`Data::Dumper` now understands the new class-object representation through
class-object/hash conversion APIs. The XS and pure-Perl Data::Dumper paths
were updated in [`dist/Data-Dumper`](https://github.com/demerphq/perl5/tree/xperl/main/dist/Data-Dumper/), with compatibility guards for building
the distribution on older Perl versions. The class-object support is
documented and tested.

Related POD: [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlclass.pod), [`pod/perlfunc.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlfunc.pod), and [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod)
describe the class-object APIs and their user-visible integration.
Distribution-specific history is in [`dist/Data-Dumper/Changes`](https://github.com/demerphq/perl5/blob/xperl/main/dist/Data-Dumper/Changes); no separate
Data::Dumper POD document was added for this change.

## Bundled distribution changes

### Cpanel::JSON::XS

`Cpanel::JSON::XS` was added as a bundled core distribution, including its XS
implementation, Perl support files, command-line utility, test suite, JSON
specification fixtures, extended tests, metadata, and core maintainer/build
integration.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) records the bundled-core change. The imported
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

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) records the bundled distribution change.
Tensor-specific design and status are documented in
[`dist/Tensor-XS/Changes`](https://github.com/demerphq/perl5/blob/xperl/main/dist/Tensor-XS/Changes), [`dist/Tensor-XS/XS_DESIGN.md`](https://github.com/demerphq/perl5/blob/xperl/main/dist/Tensor-XS/XS_DESIGN.md),
[`dist/Tensor-XS/NOTES.md`](https://github.com/demerphq/perl5/blob/xperl/main/dist/Tensor-XS/NOTES.md), and the other design and result Markdown files in
that distribution; no dedicated core POD document was added.

## Test and development workflow

The branch adds or changes substantial test coverage for generators, classes,
roles, namespaces, tensors, Data::Dumper, and Cpanel::JSON::XS. It also adds
test-harness behavior for saved timing data, including a very high default
weight for files without timing information so new tests are scheduled early.

Agent-oriented repository guidance and subsystem skills were added under
[`.agent/`](https://github.com/demerphq/perl5/tree/xperl/main/.agent/), with related
root instructions. Development plans are kept under
[`planning/`](https://github.com/demerphq/perl5/tree/xperl/main/planning/) and
excluded from generated distribution manifests while remaining tracked source
files.

Several tests were adjusted for root-directory execution, generated-file
checks, experimental warning handling, and bundled-distribution layout.

Related POD: no dedicated POD document was added for the test-harness and
agent-workflow changes. Their operational documentation is in
[`AGENTS.md`](https://github.com/demerphq/perl5/blob/xperl/main/AGENTS.md),
[`.agent/skills/`](https://github.com/demerphq/perl5/tree/xperl/main/.agent/skills/), and the tracked materials under
[`planning/`](https://github.com/demerphq/perl5/tree/xperl/main/planning/).

## Generated and platform integration

Because the branch changes keywords, features, opcodes, embedding declarations,
interpreter variables, parser grammar, warnings, and bundled distributions,
the comparison includes regenerated parser and header artifacts. Build and
platform integration changes appear in
[`Configure`](https://github.com/demerphq/perl5/blob/xperl/main/Configure),
[`Makefile.SH`](https://github.com/demerphq/perl5/blob/xperl/main/Makefile.SH),
[`Cross/`](https://github.com/demerphq/perl5/tree/xperl/main/Cross/),
[`win32/`](https://github.com/demerphq/perl5/tree/xperl/main/win32/),
[`plan9/`](https://github.com/demerphq/perl5/tree/xperl/main/plan9/), generated keyword/opcode files, and generated POD indexes.

These generated changes are consequences of the source changes above and must
be regenerated when the relevant inputs change.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) records user-visible consequences; no
separate POD document was added for the generated-file and platform
integration details.

## Compatibility posture

Most existing Perl behavior is intentionally preserved where practical, and
the branch contains compatibility fixes for feature-disabled code, `CORE`
handling, threaded builds, and bundled distributions. Nevertheless, the
features listed here are experimental and the project explicitly permits
incompatible changes when they are judged necessary for the fork's goals.

Related POD: [`pod/perldelta.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perldelta.pod) records notable user-visible differences,
while [`pod/perlexperiment.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlexperiment.pod), [`pod/perlgenerator.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlgenerator.pod), [`pod/perlclass.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlclass.pod), and
[`pod/perlnamespace.pod`](https://github.com/demerphq/perl5/blob/xperl/main/pod/perlnamespace.pod) document the experimental features themselves.
