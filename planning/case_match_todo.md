# `case`/`match` follow-up work

## September 10 correctness follow-up

The eleven problem groups in
[`case_match_coverage_review.md`](case_match_coverage_review.md) are fixed.
The expanded regression suite covers native scalar provenance, encoding and
byte mode, sparse arrays, reference identity, one-fetch capture binding,
hash-key validation, invalid referent kinds, and subject/field-view ownership.
Broader sanitizer and cross-build validation remain separate follow-ups;
the current build is nonthreaded, non-DEBUGGING, and optimized with `-O3`.
The full harness passes: 3,084 files, 1,393,802 tests. All 367 applicable
case/match tests pass; thread-specific tests are skipped in this build.

This document records the remaining work for the experimental
`case_match` feature on the `xperl/case_match` branch.  It is intentionally
implementation-focused: the broader language proposal remains in
[`perl-pattern-matching.md`](perl-pattern-matching.md).

The September 9 implementation review found six defects in previously
covered areas: escaped capture lifetime, multi-regex capture discovery,
nested builtin booleans, silent size limits, slurp-minimum overflow, and
duplicate hash keys. Fixes and expanded regressions are complete; broad
validation is tracked in
[`case_match_review_fixes.md`](case_match_review_fixes.md).

Status labels mean: `COMPLETE` is implemented and has focused coverage;
`PARTIALLY COMPLETE` has a working baseline but still needs specified
extensions or broader hardening; `OPEN` is unfinished; and `DEFERRED` is
intentionally postponed.

## Deferred correctness and numeric-semantics review

### Borrowed capture lifetime across pattern calls — DEFERRED, HIGH PRIORITY

A later pattern call can remove or replace a source element whose SV an
earlier capture still borrows. Before publication, that capture can lose its
value or trigger an internal error. This remains an unresolved correctness
issue; deferral does not make the behavior supported or safe.

When resumed, establish ownership of tentative captures across callbacks,
backtracking, exceptions and publication, preserving reference identity.
Audit related subject and temporary-binding lifetimes, and add mutation,
exception and sanitizer coverage. See the reproducer and analysis in
[`case_match_followup_review_20260910.md`](case_match_followup_review_20260910.md).
The tail-copy fix does not resolve ordinary borrowed scalar captures.
Further callback probes and repair options are recorded in
[`case_match_capture_lifetime_analysis.md`](case_match_capture_lifetime_analysis.md).

### Integer versus float distinctions and HV equality — DEFERRED

As part of deciding whether matching should distinguish integers and floats,
assess the consequences of Perl's scalar type tracking for every backend.
Currently forced HV dispatch distinguishes integer and floating-point keys:
`1.0` misses `match(1)` and `1` misses `match(1.0)`, unlike the other backends.
Keep this discrepancy recorded rather than changing numeric semantics now.

Reconciling the representations may be impractical within this feature's
scope. HV dispatch is retained for performance comparisons, is not the
automatic default, and may be removed because of its performance. Revisit
its equality behavior only alongside the numeric-type decision and the
decision whether to retain that backend. Preserve the existing opt-in
reproducers for comparison; do not treat the discrepancy as fixed.

## Documentation-derived design questions

### Tail capture copying versus aliasing — OPEN

Tail bindings currently copy element values rather than alias source slots.
References retain their referent identity; aggregates are not deep-copied.
Before settling the API, decide once and for all whether tail bindings
should continue to copy or should alias instead. Until that decision,
implementation, tests and documentation must consistently use copying.

Also settle retention versus snapshotting for scalar observations made by
constraints. The current runtime retains the original SV until publication,
so in-place callback assignments remain visible; it does not freeze the
observed value. Distinguish this choice from aliasing the final pad scalar:
publication still copies into that scalar.

These questions were extracted from the case/match guide and do not change
the current documented spellings.

### Naming value-kind criteria — OPEN

The current names are `DefinedVal`, `ScalarVal`, `RefVal`, and `ObjectVal`.
Decide whether future aliases or replacements should instead mirror existing
builtins such as `defined`, `scalar`, `ref`, and `blessed`.  Do not change the
current names until the language design is settled.

### Naming native numeric criteria — OPEN

The current names are `Int` and `Float`.  Decide whether they should remain
distinct from `Num`, or whether a more regular naming scheme is wanted before
exposing them as stable syntax.

### Documentation organization and examples — COMPLETE

Naming and pinning now appear alongside bindings and guards.  The guide has
runnable opening and closing examples with expected output, a boolean
comparison table, separate explanations of the two Strict forms, and concrete
aggregate, class, and conversion examples.  The closing example draws on
`t/comp/case_match_examples.t`, which remains the broader feature tour.

## Documentation-derived implementation items — COMPLETE

The recent documentation notes are now reflected in the implementation and
focused tests:

- `DefinedVal()` performs a defined-value check and can bind one scalar target;
- `Int()` and `Float()` distinguish native integer and floating-point values;
- `true` and `false` retain boolean-value matching, while `TRUE` and `FALSE`
  use ordinary truth-value matching inside a data-shape;
- `Strict(NumEq(...))` rejects strings with no numeric prefix without causing
  the ordinary numeric warning;
- array slurp minima are stored in the full pattern count rather than being
  limited to 255.

## Current baseline

The branch currently provides:

- `use feature 'case_match'` and the block-only form
  `case (EXPR) { match (PATTERN) { ... } }`;
- one-time subject evaluation, case-local subject names with `as`, and
  `with` pins, including `with (EXPR as $name)`;
- direct pattern pinning with `^$name`, using an existing scalar lexical and a
  case-entry snapshot shared by all clauses;
- scalar patterns for `undef`, booleans, numeric literals, string literals,
  and the wildcard `_`;
- numeric criteria `Int`, `Float`, `IntStr`, `FloatStr`, `Num`, and `NumStr`,
  with optional `Strict` checks, plus matching-only `NumEq` using Perl's
  numeric equality semantics;
- value-kind criteria `DefinedVal`, `ScalarVal`, `RefVal`, and `ObjectVal`,
  plus the `TRUE` and `FALSE` truth-value criteria;
- explicit `ToInteger`, `ToFloat`, and `ToString` subject coercions;
- tentative lexical bindings with commit/rollback behavior;
- exact and open nested array/hash-reference patterns using edge `...`
  markers, including leftmost subsequence matching;
- regex data-shape patterns, including ordinary captures and clause-local
  bindings for named captures;
- string concatenation patterns with multiple scalar captures, including
  prefix, suffix, sandwich, pinned, empty, and leftmost-shortest captures;
- scalar and nested scalar-reference patterns, such as `\$value` and
  `\\$value`, which bind the referent rather than the outer reference;
- unrestricted ordinary Perl guards inside `match (...)`;
- labels and ordinary block control flow in clause bodies;
- constant-only dispatch using linear arrays, binary search, or an HV lookup,
  with development selection through `PERL_CASE_DISPATCH`;
- domain metadata and min/max rejection for string lengths, integer values,
  and floating-point values;
- documentation in `pod/perlcasematch.pod`, `pod/perlsyn.pod`, and
  `BLEAD-DELTA.md`;
- focused compiler/runtime coverage in `t/comp/case_match.t`;
- a single readable feature showcase in `t/comp/case_match_examples.t`.

The case/match implementation now has dedicated case and clause operations.
It does not construct case clauses through the legacy given/when block builder,
and its runtime dispatch is separate from given/when semantics.  The remaining
work below is therefore hardening and extension, not a replacement of the
basic control-flow representation.

## Priority 1: make the basic implementation correct and maintainable

### Native-class implicit capture regression — COMPLETE

Running the proposed guide example exposed a defect on 2026-09-09:

```perl
use feature qw(case_match say class);
class Position {
    field $x :param;
    field $y :param;
}
case (Position->new(x => 3, y => 4)) {
    match (Position { '$x' => $x, '$y' => $y }) {
        say "position: $x, $y";
    }
}
```

This previously exited with SIGSEGV.  Using different undeclared capture
names avoided the crash but produced empty values.  Predeclared targets hid
the defect because the pattern compiler incorrectly redirected captures to
older same-named declarations, including class field pad entries.

Pattern preparation now replaces captures closed by the temporary parser
scope with new declarations in the match clause, before parsing the guard
and body.  Pattern pad references are updated by index, and the fallback
search for older names has been removed.  Tests cover field-name collisions,
guards, shadowing, nested objects, array tails, pins, typed captures, UTF-8
names, and repeated execution.  The guide now uses implicit field captures.

The broader validation also exposed a separate slurp cleanup defect: the
minimum count in `OP_CASECOERCE::op_targ` was passed to `pad_free()` as a pad
index.  Opcode cleanup now clears that count before generic pad cleanup.
A fresh-process regression repeatedly compiles and destroys a pattern using
the maximum U32 minimum without allocating a correspondingly large array.

### 1a. Never silently ignore unsupported syntax — COMPLETE

Status: the validator and concat matcher now reject unsupported structural
syntax instead of treating it as a non-match or silently evaluating it as
ordinary Perl.

This is a permanent case/match invariant.  Every pattern form must either be
implemented according to its documented data-shape rules or throw an explicit
exception.  In particular, unsupported operators, calls, malformed
concatenation boundaries, duplicate capture targets, and adjacent captures
must not be discarded or misinterpreted.  New pattern forms must add focused
negative tests proving that unsupported variants fail visibly.

### 1. Make pattern compilation ownership explicit — OPEN

Status: the current implementation works for the focused suite, but ownership
is not yet audited systematically across cloning, failed matches, exceptions,
and destruction.

The pattern auxiliary tree must have clear ownership rules for every retained
`OP`, `SV`, and auxiliary array.  In particular:

- the executable optree must own executable expression operations;
- the compiled pattern representation must not retain freed operations;
- threaded cloning must duplicate or share each retained value correctly;
- destruction must release every owned binding and auxiliary value exactly
  once;
- temporary values created while matching must not leak on failed clauses,
  failed guards, exceptions, or nested backtracking.

The simple concatenation implementation currently marks concat operations so
the normal multiconcat optimizer leaves their structure intact.  This should
be reviewed against future optimizer changes and covered by an explicit
ownership/regression test.

### 2. Duplicate constant patterns — COMPLETE

Status: implemented and covered by focused tests.  Duplicate pure-constant
patterns warn and retain the earliest reachable clause; guarded and dynamic
patterns remain distinct.

For pure constant cases, duplicate values cannot select different clauses: only
the earliest source clause is reachable.  The implementation currently retains
the earliest clause for dispatch purposes.  The compiler now emits a C<syntax>
warning saying that the duplicate pattern will never match, while preserving
first-clause semantics.

Guarded and dynamic clauses must not be deduplicated because their evaluation may
have side effects and their guards can distinguish otherwise equal patterns.
The warning identifies the duplicate value and its source location.  Reporting
the original clause's source location as well remains optional diagnostic
polish rather than a semantic gap.

## Post-v0 follow-up: dispatch optimization

The following work is intentionally outside the v0 completion checklist.  The
current dispatch implementations are functional and covered by development
benchmarks; these items can be revisited after the semantics and ownership
model have stabilized.

### Post-v0.1. Audit optimized representations and cloning

Status: the array and HV dispatch forms exist and are usable, but their
representation, ownership, and cloning behavior have not received a complete
cross-build audit.  This is intentionally deferred while the feature semantics
settle.

Keep the array and HV strategies distinct:

- array strategy: typed value arrays plus parallel clause-index arrays;
- HV strategy: canonical typed key construction followed by HV lookup;
- neither strategy should construct data structures belonging to the other;
- all retained values should use normal Perl-owned `AV`/`SV` structures where
  that is practical for cloning and cleanup.

The domain model should explicitly represent whether each domain is present:

- `undef` presence;
- boolean true/false presence;
- sorted IV values;
- sorted NV values;
- sorted PV values.

Absent domains must not be represented by ambiguous zero values.  IV and UV
  bounds must remain exact and must not be converted through NV.  String
  bounds must use scalar lengths without constructing unnecessary temporary
  strings.

### Post-v0.2. Improve dispatch selection

Status: provisional strategy selection is implemented and benchmark tooling has
been used during development.  The thresholds and build/type-specific tuning
are not considered final.

The current automatic policy is provisional: linear probing below 16 clauses and
binary search at 16 clauses or above.  Benchmark and tune the crossover by:

- scalar domain;
- clause count, including 2 through at least 2048;
- first, middle, and last hits;
- misses below the minimum, above the maximum, and inside the range;
- short and long strings;
- threaded and non-threaded builds;
- debugging and production optimization levels.

The benchmark must compare:

- ordinary `if`/`elsif`/`else` code;
- existing optree case execution;
- case array-linear dispatch;
- case binary dispatch;
- case HV dispatch;
- later, compiler-generated conditional trees.

Use sufficiently long timed runs to avoid “not enough iterations” warnings,
but keep ordinary measurements practical.  Record the build configuration,
compiler, CPU, and exact benchmark command.  Keep benchmark scripts and
results under `planning/scripts/`; they are developer tools, not language
interfaces.

### Post-v0.3. Add conditional-tree lowering

Status: not implemented.  Current constant dispatch still uses the dedicated
case machinery; no conditional optree is generated yet.

For small pure constant cases with no guards, generate an ordinary conditional
optree when it is faster than the generic case machinery.  The generated
structure must preserve:

- typed constant semantics;
- first-clause behavior after duplicate handling;
- wildcard/default placement, including a default in the middle;
- miss behavior;
- case result context;
- case labels and `last`/`next`/`redo` behavior;
- one-time subject fetching.

The generated tree should be visible to `B::Deparse` as the corresponding
conditional structure when deparsing at the relevant level.  Choose a subject
temporary that cannot collide with names used by the case or clause bodies, and
ensure its lifetime covers the complete generated conditional.

Do not lower cases containing dynamic patterns, captures, pins, guards, or
unsupported composite forms.  Add a development-only way to disable lowering
for comparison tests.

## Priority 2: complete pattern semantics

### 3. Composite scalar patterns — COMPLETE

Status: multiple-capture literal concatenation is implemented and tested for
prefix, suffix, sandwich, pinned, empty, and repeated-boundary cases.  The
matcher resolves captures left to right and chooses the shortest value bounded
by the next non-empty literal or pinned fragment.

The v0 rules for completing this form are now settled:

- multiple non-adjacent captures are allowed;
- captures are resolved left-to-right using the shortest value bounded by the
  next literal or pinned fragment;
- adjacent unbounded captures are illegal and must throw an exception;
- a capture name may occur at most once in a concatenation pattern, so repeated
  captures such as `$x . "-" . $x` are also illegal;
- empty captures are allowed;
- concatenation is the only structural expression supported for now;
- operands must be strings or values with usable overloaded stringification;
  numeric coercion is not part of this pattern form;
- normal Perl string, magic, Unicode, byte, and overload semantics apply;
- the subject and pinned operands are evaluated once per match attempt.

The following extensions remain deliberately deferred: richer structural
operators, numeric coercion within concatenation, repeated capture names, and
regex fragments embedded in string concatenation.  Unsupported forms must
continue to throw rather than silently falling back to another interpretation.

Zero-argument function and method calls remain supported as standalone scalar
pattern values.  They are not admitted as concatenation components.  Do not
silently evaluate calls with arguments, arithmetic, or other arbitrary Perl
expressions as pattern syntax.  If richer pattern expressions are eventually
allowed, specify exactly which operators are structural and how bindings are
obtained.

### 4. Regex-pattern hardening — COMPLETE

Status: the currently specified static-regex behavior is implemented and
covered, including named captures, nonparticipating captures, localization,
open searches, and rejection of dynamic regex patterns and regex code blocks.

Regex data shapes, ordinary captures, named clause-local bindings, `undef`
for nonparticipating named captures, duplicate-capture delegation to the regex
engine, static compile-time compilation, open-search reuse, and case-local
capture restoration are implemented.  Regex code blocks are rejected rather
than silently discarded.  Dynamic regex construction is deliberately rejected
in a data-shape pattern for now; only a regular expression written as a static
pattern is accepted there.  Runtime-built regular expressions belong in the
ordinary Perl guard after `if`, where their normal evaluation rules apply.

Unicode and byte-string behavior remains the responsibility of the regex
engine, and the focused tests verify that the case matcher does not interfere
with it.  Future work may revisit dynamic regex patterns or regex code blocks,
but either change would need a separate specification for evaluation count,
side effects, and repeated candidates.

A non-participating named capture is a named group whose branch was not taken
by the successful regex match.  It remains a clause-local binding with the
undefined value, following the regex engine's result.

### 5. Object and class patterns — PARTIALLY COMPLETE

Status: the initial structural object-pattern slice and native class
field-map/PTROBJ support are implemented and covered by focused acceptance
tests.  Blessed hash, array, and scalar-reference objects can be matched and
destructured; object captures are resolved to clause lexicals at compile time,
and array slurp targets retain their underlying array pads.

The first structural object-pattern slice is implemented and documented.  A
class-qualified pattern can now match and destructure blessed hash references,
blessed array references, and blessed scalar references.  Hash fields use
quoted field names, array fields are positional, and a trailing hash ellipsis
allows extra fields.  Class compatibility is checked without calling
constructors, accessors, overload methods, or arbitrary user methods.
For v0, a class-qualified pattern requires the object's exact class;
inheritance and role membership do not satisfy it.

Regression coverage is in `t/comp/case_match.t` for captures, exact versus open
hash shapes, positional array shapes, scalar-reference shapes, and class
mismatches.  The implementation resolves captures from the temporary lexical
scope produced by the class-qualified parser form to the clause's lexicals
during pattern compilation.

Still open for this item:

- a post-v0 `isa` pattern/operator for inheritance checks, followed by a
  separate decision about role-membership matching;
- broader field magic, tied-value, exception, alias, and reference-identity
  coverage beyond the v0 acceptance cases;
- a cleaner grammar path for class-qualified reference forms that avoids the
  ordinary indirect-method-call representation.

The v0 acceptance cases now verify these settled rules:

- a pinned reference compares by identity, while a reference capture binds the
  referent normally and does not clone it;
- native class fields are read directly, without accessors or arbitrary
  methods, and a missing field is a non-match unless field access itself
  raises an exception;
- tied or magical nested values follow ordinary Perl read semantics;
- overloaded nested values are invoked only when the selected pattern requires
  string, numeric, or boolean conversion; structural object matching does not
  stringify the whole object;
- captured references preserve their original identity.

## Post-v0 follow-up: additional pattern forms

These language extensions are intentionally outside the v0 completion
checklist.  They require separate grammar and semantic decisions after the
current structural matcher has settled.

### Post-v0.4. Additional pattern forms

Status: not implemented beyond the currently supported single final array
slurp and minimum-length form.  Alternatives, ranges, optional fields,
multiple variable-length captures, user protocols, and expression-valued
clauses remain intentionally deferred.

These remain deliberately deferred until the current foundation is stable:

- alternatives;
- ranges;
- optional fields;
- richer array slurps and multiple variable-length captures;
- user-defined pattern protocols;
- signature and function-head dispatch;
- expression-valued or arrow-form clauses.

Each form needs grammar, binding, rollback, context, error, and optimizer
rules before implementation.

## Priority 3: context, exceptions, and compatibility

### 6. Context and result behavior — COMPLETE

Status: the supported v0 pattern forms have been audited in scalar, list, and
void contexts by the focused compiler/runtime and hardening suites.

The implementation confirms that:

- the selected clause supplies the `case` result;
- scalar/list behavior is ordinary Perl behavior;
- no-match returns `undef` in scalar context and an empty list in list
  context;
- an empty result from a matched clause is distinguishable from no match only by
  the documented result/context rules;
- subject evaluation and pattern evaluation do not accidentally change
  context.

### 7. Exception and cleanup behavior — COMPLETE

Status: the supported v0 exception and cleanup paths have focused coverage.
The remaining sanitizer work is tracked under item 9 and is validation work,
not an unresolved v0 semantic rule.

The focused suite verifies nested and outer `eval`, `die` in subjects, patterns,
guards, and clause bodies, plus cleanup and destruction paths.  It confirms:

- tentative bindings roll back on every failure path;
- `$@`, `$!`, localization, and scope restoration follow normal Perl rules;
- cleanup runs with the correct case state installed;
- nested cases restore their parent state;
- fatal interpreter-wide failures remain interpreter-wide.

### 8. Magic, aliases, and mutation — COMPLETE

Status: the supported v0 magic, alias, identity, mutation, and lifetime
semantics have focused coverage.

The focused suite covers:

- tied scalar, array, and hash subjects;
- overloaded values;
- read callbacks occurring only as specified;
- writes from a clause to the original subject;
- aliases and references preserving identity;
- localization and destruction of bound values;
- mutation of the subject from the clause and its effect on later code.

The case subject should be fetched once for matching, while the clause body must
still be able to modify the original lvalue.

### 9. Threaded and cloning support — PARTIALLY COMPLETE

Status: threaded case contexts, cloned pattern representations, DEBUGGING, and
destruction-level focused runs pass.  Full sanitizer and cross-configuration
validation remain open.

The focused suite has been run under the current threaded DEBUGGING build and
with `PERL_DESTRUCT_LEVEL=2`, including thread-clone and nested-context tests.
Still to do is the same focused matrix under a non-threaded build, followed by
ASAN and LSan configurations.  Leak runs must use `PERL_DESTRUCT_LEVEL=2`;
reports from ptrace-restricted processes are not valid LSan evidence.

### Current hardening-pass findings

The focused hardening pass is in
`t/comp/case_match_hardening.t` and
`t/comp/case_match_hardening_tail.t`, together with
`t/comp/case_match_threads.t`.  All five case/match files pass: 158 tests in
the current focused harness.

The coverage now verifies:

- scalar, list, and void result behavior, including a matched empty list;
- one-time tied scalar subject fetches and writes from a clause;
- tied array and hash reads through normal magic;
- overloaded scalar matching without applying stringification to structural
  object matching;
- reference-capture identity and mutation of original aggregate subjects;
- exception propagation from subjects, zero-argument patterns, guards, and
  clause bodies;
- nested `eval` catching a case-internal exception;
- binding rollback after a guard exception;
- normal localization cleanup;
- release of captured scalar and array values at the case boundary;
- nested case state restoration after both ordinary success and cleanup.

The hardening work fixed three real defects: case binding cleanup used the old
two-field representation after array bindings became triples, tied aggregate
matching bypassed magic-aware size/value access, and optimized dispatch could
ignore stringification overloads.  A guard exception that used to SIGSEGV now
rolls back bindings and propagates normally.

Remaining limitations are tracked by the numbered items above.  In
particular, selected clause expressions receive scalar, list, or void
context, as verified by calls to real subroutines. Broader ownership and
sanitizer validation remain under items 1 and
9; items 6–8 are complete for the supported v0 semantics.

## Documentation maintenance

The main documentation for the currently implemented feature is in place.
Whenever semantics change, update the related documents together:

- `pod/perlcasematch.pod` in a beginner-friendly, CS-101 style;
- `pod/perlsyn.pod` for syntax and precise semantics;
- `pod/perlfunc.pod` if new pattern-related functions or keywords require
  entries;
- `pod/perldiag.pod` for diagnostics;
- `pod/perlexperiment.pod` for experimental status;
- `pod/perldelta.pod` and `BLEAD-DELTA.md` for branch-visible differences;
- `B::Deparse` and its tests;
- keyword/opcode regeneration inputs and all generated outputs.

Every parser or opcode change must be followed by the appropriate regeneration
using the system Perl, and the grammar must remain conflict-free.  Focused
tests should be runnable from both the repository root and the `t/` directory.

## Suggested execution order for the remaining work

1. Complete the ownership audit and non-threaded/cloning/sanitizer validation.
2. Synchronize documentation and generated files as semantics change.
3. Run focused suites, porting checks, `make regen`, and finally `make_test`.

Post-v0 work begins with the dispatch optimization section above, followed by
the additional pattern forms section.

Do not mark the v0 feature complete until the active implementation,
exception/cleanup paths, documentation, and the full relevant test matrix all
agree with one another.  The dispatch and language-extension sections above
are explicitly post-v0 follow-up work and are not prerequisites for that
milestone.
