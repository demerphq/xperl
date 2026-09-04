# `case`/`match` follow-up work

This document records the remaining work for the experimental
`case_match` feature on the `yves/pattern_match` branch.  It is intentionally
implementation-focused: the broader language proposal remains in
[`perl-pattern-matching.md`](perl-pattern-matching.md).

## Current baseline

The branch currently provides:

- `use feature 'case_match'` and the block-only form
  `case (EXPR) { match (PATTERN) { ... } }`;
- one-time subject evaluation, case-local subject names with `as`, and
  `with` pins, including `with (EXPR as $name)`;
- scalar patterns for `undef`, booleans, numeric literals, string literals,
  and the wildcard `_`;
- explicit `IntVal`, `FloatVal`, and `StrVal` subject coercions;
- tentative lexical bindings with commit/rollback behavior;
- exact and open nested array/hash-reference patterns using edge `...`
  markers, including leftmost subsequence matching;
- regex predicate patterns;
- simple string concatenation patterns with one scalar capture, including
  prefix, suffix, sandwich, pinned, and empty captures;
- unrestricted ordinary Perl guards inside `match (...)`;
- labels and ordinary block control flow in clause bodies;
- constant-only dispatch using linear arrays, binary search, or an HV lookup,
  with development selection through `PERL_CASE_DISPATCH`;
- domain metadata and min/max rejection for string lengths, integer values,
  and floating-point values;
- documentation in `pod/perlcasematch.pod`, `pod/perlsyn.pod`, and
  `BLEAD-DELTA.md`;
- focused compiler/runtime coverage in `t/comp/case_match.t`.

The current implementation still uses parts of the existing `given`/`when`
control-flow machinery internally.  That is an implementation detail, but it
is also the main area where the current runtime does not yet match the clean
long-term design.

## Priority 1: make the basic implementation correct and maintainable

### 1. Give case/match independent control-flow implementation

The current optree contains case-specific entry/leave operations layered onto
the older `given`/`when` machinery.  This must be replaced: `case`/`match`
and `given`/`when` are alternatives at the language level, but they must not
share non-trivial implementation machinery.  In particular, removing one
feature should not change the other, and case/match must not inherit switch
fall-through, smartmatch, or other legacy control-flow behavior.

The preferred target is a case-specific structure equivalent to:

```text
entercase
    casedispatch or ordered clause tests
        clause body
leavecase
```

Requirements:

- no implicit fall-through;
- exactly one clause runs;
- the case behaves as a labelled block;
- `last LABEL` exits the case;
- `next LABEL` leaves the current case execution and enters the next labelled
  iteration when the surrounding construct gives it loop semantics;
- `redo LABEL` restarts the labelled case subject evaluation and clause search;
- nested cases do not corrupt the outer case context;
- legacy `given`/`when` behavior remains unchanged.

Introduce dedicated case operations and runtime context handling, and remove
the unnecessary given/when layers from case/match.  Small, genuinely generic
helpers may remain shared only when they have no feature-specific semantics;
the case and given/when operation trees, context types, and dispatch paths
must otherwise be independently maintainable.

### 2. Make pattern compilation ownership explicit

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

### 3. Clarify and enforce duplicate rules

For pure constant cases, duplicate values cannot select different clauses: only
the earliest source clause is reachable.  The implementation currently retains
the earliest clause for dispatch purposes.  Decide and implement the user-facing
rule:

- either reject duplicate constant clauses at compile time;
- or emit an experimental warning while preserving first-clause semantics;
- or document silent first-clause deduplication as intentional.

Guarded and dynamic clauses must not be deduplicated because their evaluation may
have side effects and their guards can distinguish otherwise equal patterns.
The diagnostic should identify the duplicate pattern and, where practical,
both source locations.

## Priority 2: finish constant dispatch

### 4. Complete the optimized representations

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

### 5. Improve dispatch selection

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

### 6. Add conditional-tree lowering

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

## Priority 3: complete pattern semantics

### 7. Composite scalar patterns

The current implementation supports one unpinned scalar capture surrounded by
literal concatenation fragments.  Define and test the next boundary before
implementing it:

- multiple captures;
- ambiguous splits and their leftmost/rightmost rule;
- adjacent captures;
- pinned and unpinned operands mixed together;
- Unicode and byte strings;
- magical and tied operands;
- empty literal fragments;
- whether any additional simple operators are admitted.

Do not silently evaluate arbitrary calls or arithmetic as pattern syntax.
If a richer pattern expression is eventually allowed, specify exactly which
operators are structural and how bindings are obtained.

### 8. Regex patterns

The current runtime supports regex predicates.  Remaining work includes:

- named-capture bindings committed transactionally;
- behavior for duplicate named captures;
- behavior for captures that did not participate;
- evaluation of subject and regex exactly once;
- Unicode, byte, magic, and tied-subject behavior;
- rejection or explicit handling of `(?{ ... })` and `(??{ ... })` code blocks;
- preservation of `$1`, `$2`, `%+`, and related legacy behavior outside the
  pattern-binding interface.

### 9. Object and class patterns

Add object/class destructuring only through an explicit, documented protocol.
Pattern matching must not call constructors or arbitrary methods merely to
inspect an object.  Coordinate this work with the class field map and the
existing `implements` metadata.

Define behavior for:

- class instances with declared fields;
- subclasses and roles;
- blessed hash/object values without declared fields;
- field accessors, magic, and overloaded values;
- failed field reads and exceptions;
- aliases and reference identity.

### 10. Additional pattern forms

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

## Priority 4: context, exceptions, and compatibility

### 11. Context and result behavior

Test every supported pattern and clause form in scalar, list, and void context.
Confirm that:

- the selected clause supplies the `case` result;
- scalar/list behavior is ordinary Perl behavior;
- no-match returns `undef` in scalar context and an empty list in list
  context;
- an empty result from a matched clause is distinguishable from no match only by
  the documented result/context rules;
- subject evaluation and pattern evaluation do not accidentally change
  context.

### 12. Exception and cleanup behavior

Verify nested and outer `eval`, `die` in subjects, patterns, guards, and clause
bodies, plus exceptions during cleanup and destruction.  Confirm:

- tentative bindings roll back on every failure path;
- `$@`, `$!`, localization, and scope restoration follow normal Perl rules;
- cleanup runs with the correct case state installed;
- nested cases restore their parent state;
- fatal interpreter-wide failures remain interpreter-wide.

### 13. Magic, aliases, and mutation

Expand tests for:

- tied scalar, array, and hash subjects;
- overloaded values;
- read callbacks occurring only as specified;
- writes from a clause to the original subject;
- aliases and references preserving identity;
- localization and destruction of bound values;
- mutation of the subject from the clause and its effect on later code.

The case subject should be fetched once for matching, while the clause body must
still be able to modify the original lvalue.

### 14. Threaded and cloning support

Run the complete focused suite under threaded and non-threaded builds.  Add
tests for cloning compiled pattern representations, values, pads, and case
contexts.  Then exercise DEBUGGING, ASAN, and LSan configurations.  Leak runs
must use `PERL_DESTRUCT_LEVEL=2`; reports from ptrace-restricted processes are
not valid LSan evidence.

## Priority 5: tooling and documentation

Update together whenever semantics change:

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

## Suggested execution order

1. Add duplicate-pattern diagnostics and close ownership/cleanup gaps.
2. Audit and, if justified, replace the remaining given/when control-flow
   layers.
3. Finish benchmark coverage and tune constant dispatch.
4. Implement small-case conditional-tree lowering.
5. Add regex named bindings and then object/class patterns.
6. Expand context, exception, magic, mutation, cloning, and sanitizer tests.
7. Synchronize all documentation and generated files.
8. Run focused suites, porting checks, `make regen`, and finally `make_test`.

Do not mark the feature complete until the implementation, optimizer behavior,
exception/cleanup paths, documentation, and the full relevant test matrix all
agree with one another.
