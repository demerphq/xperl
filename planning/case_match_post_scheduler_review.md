# Case/match review after constraint scheduling

Reviewed September 10, 2026, after commit `1d2cef14af`.

This report compares `pod/perlcasematch.pod`, the implementation, and the
case/match tests after the capture-ownership and constraint-first changes.
It was reconstructed from the session record after accidental deletion;
the wording is not a byte-for-byte recovery of the original file.

## Scope and status

Initial probes used the nonthreaded, non-DEBUGGING production interpreter.
Two straightforward defects have source fixes and regression tests in the
working tree. Four further findings need follow-up, as described below.
Do not interpret the earlier ownership validation as validation of these
new changes.

## Fixes in the working tree

### 1. Duplicate regex capture names must follow source order

The documented rule for a name appearing in separate regexes in one clause
is that the first regex in source order supplies the lexical capture. Later
uses produce a warning. This is distinct from duplicate groups within one
regex, which remain the regex engine's responsibility.

Constraint scheduling exposed a runtime-order bug:

```perl
case (['a', ['b']]) {
    match ([/(?<x>a)/, [/(?<x>b)/]]) {
        say "$x,$+{x}";
    }
}
```

The nested array's regex can execute before the outer regex. Before the
fix, the lexical came from whichever regex executed first, producing
`b,a` instead of `a,a`.

The fix assigns named-capture ownership during source-order traversal of
the compiled shape. Later regexes still execute and update ordinary regex
captures normally, but cannot take ownership of the same lexical.

Regression coverage includes:

- nested shapes whose scheduling order differs from source order;
- a nonparticipating source-first capture, which must bind `undef`; and
- open-array candidate retries with duplicate names.

The guide now explains that source order wins even when execution order
differs. The existing warning remains in place.

### 2. Hash wildcards must check presence without fetching values

For `{ present => _, ... }`, matching needs to establish that the key
exists, not read its value. Previously a tied hash's `FETCH` was called,
even though an array wildcard already avoided the equivalent read.

The fix uses a shared wildcard recognizer and checks hash-key presence
without fetching the value. It applies to ordinary hash shapes and
class-qualified hash shapes. Missing keys still fail the match.

Tests use tied hashes whose `FETCH` dies, verify successful presence checks
and unsuccessful missing-key checks, and count `EXISTS` calls. The guide
now states the no-fetch behavior explicitly.

### 3. Computed-call documentation

The guide clarifies that a shape call executes only if checking reaches
it. Searches may reach it for more than one candidate; there is no promise
of one call for the whole clause or global result caching.

## Additional regression coverage

The review test file grew from 242 to 256 assertions. In addition to the
fix-specific tests, it now checks:

- an 81-pair matrix of repeated and pinned scalar comparisons, covering
  definedness, empty strings, numeric-looking values, and reference
  identity; and
- preservation of exception-object identity when a shape call throws.

The comparison oracle distinguishes `undef` from every defined value,
compares references by identity, and otherwise compares strings. The
matrix and exception test passed before the two new source fixes; the
regex-order and hash-wildcard regressions reproduced their defects.

## Remaining findings

### 1. Mixed capture producers can make equality order-dependent — OPEN

An ordinary capture and a concatenation capture using the same name do
not consistently enforce agreement:

```perl
case (['a', 'xb']) {
    match ([$x, 'x' . $x]) { say "hit:$x" }
    match (_)             { say 'miss' }
}
```

The probe printed `hit:b`. Reversing the shape and corresponding subject
made it miss. Concatenation capture insertion can append a second binding
for the same pad slot without comparing the previously recorded value.

Decide whether mixed capture producers must enforce equality or whether
some combinations should be rejected. Then cover ordinary, typed, regex,
and concatenation captures in both orders. This has not been fixed.

### 2. Empty exact array and hash shapes — COMPLETE

The probes `match([])` and `match({})` produced an unsupported-expression
error, whereas open shapes `[...]` and `{...}` worked.

Empty anonymous containers use `OP_EMPTYAVHV`, with
`OPpEMPTYAVHV_IS_HV` distinguishing hashes. The shape validator does not
accepted that representation. The fix recognizes it in validation,
class-shape discovery, constraint scheduling, and the normal container
matching paths. Class-qualified empty braces also require recognition of
the indirect-call parser's exact `SCOPE(STUB)` representation; this does
not make arbitrary empty expressions valid shapes.

Regression tests cover empty/nonempty containers, wrong referent kinds,
nested shapes, open-array searches, guards, exact class checks, native
class fields, tied containers without value fetches, constraint-first
capture avoidance, and thread cloning. On the threaded DEBUGGING build,
all six case/match files plus Deparse-core passed (4,400 tests), followed
by all 40 porting files (53,264 tests), including regeneration checks.
These runs finished September 10 at 15:05:27 and 15:06:36, respectively.
The full suite has not been rerun after the empty-shape change.

### 3. Nested searches commit locally rather than backtracking — OPEN

```perl
case ([[1, 2], 2]) {
    match ([[..., $x, ...], $x]) { say "hit:$x" }
    match (_)                   { say 'miss' }
}
```

The probe missed: the inner search selected `1`, and failure of the outer
comparison did not retry the inner search with `2`.

This needs an explicit semantic decision. If local commitment is intended,
document it and test it. If the whole shape should search for a satisfying
combination, nested candidate retry requires implementation work. No
behavior change has been made.

### 4. Direct subject identity needs clearer documentation — OPEN

In `case ($x)`, a direct `match($x)` acts like the identity/default shape,
whereas a nested occurrence such as `match([$x])` declares a capture under
the normal binding rules. The guide should explain this distinction with
small examples and corresponding focused tests.

## Validation record

The first full run after these changes finished September 10 at 13:56:25:

- all six case/match test files passed, including the expanded review file;
- 3,084 files and 1,406,233 tests ran;
- `dist/threads/t/libc.t` failed its ten thread-safe `localtime()` checks;
- `run/todo.t` unexpectedly passed tests 17, 18, 20, and 21, but those
  TODO passes did not cause the overall failure.

That run cannot serve as the requested DEBUGGING acceptance run. Although
`config_args` recorded `-DDEBUGGING`, the built interpreter did not report
DEBUGGING and core compiler commands lacked `-DDEBUGGING`. The generated
configuration also disabled `HAS_LOCALTIME_R`, and `time64.o` referenced
`localtime`, not `localtime_r`. These observations warrant a clean rebuild;
they are not evidence that the case/match changes caused the libc failure.

The clean threaded DEBUGGING rebuild and full test run passed on September
10 at 14:16:40: 3,084 files, 1,406,121 tests, 546 seconds. All six case/match
files and the previously failing libc test passed. Compiler commands include
`-DDEBUGGING`. The log is `planning/build.log` (not tracked).
