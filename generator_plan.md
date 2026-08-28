# Trial generators using one-shot continuations

Working branch: `yves/fork_sub`.

This plan was restored during a completion audit because the previous removal
was not supported by sufficient evidence.

## Audit status

- [x] Process snapshots, opcode-boundary hooks, and private stack ownership
- [x] Generator syntax, one-shot resume protocol, and explicit `generator_yield`
- [x] Nested eval, failure propagation, exhaustion, and re-entrancy
- [x] Feature/compiler diagnostics and documentation metadata
- [x] DEBUGGING and sanitizer validation
- [x] Destruction, GC, callback-context, and scheduler edge-case coverage
- [x] Final full relevant validation and cleanup

The DEBUGGING threaded build passes the focused generator, eval, loop, and
thread tests.  An isolated ASAN/DEBUGGING threaded build also passes the
generator and threaded smoke paths.  The agent sandbox cannot run
LeakSanitizer because it is ptrace-restricted, so the full generator test was
also run from the host terminal with `PERL_DESTRUCT_LEVEL=2`: all 46 tests
passed, and the direct generator smoke produced no leak report.  That full
test process still reports the two documented DEBUGGING temporary-SV teardown
diagnostics and a 176-byte indirect allocation retained by the test-process
teardown; neither reproduces in the direct generator smoke.  Cleanup coverage
includes dropping a suspended generator with a lexical object, callback
diagnostics, process-state round trips, and deterministic quantum-one
scheduler alternation.

The final scoped native harness passes all five relevant files (274 tests),
and the XS scheduler test passes all three checks.  The DEBUGGING generator
test still reports two non-fatal temporary-SV teardown diagnostics; minimal
runtime reproductions do not reproduce them, so they remain documented as a
test-harness teardown limitation rather than suppressed.

The process-local `PL_*` fields remain field-by-field snapshots.  Keep the
follow-up investigation for a contiguous execution record that could be
copied or swapped through one assignment, subject to ABI, threading, and GC
constraints.

The experimental generator trio is now `generator_create`, `generator_yield`,
and `generator_exhausted`.  `generator_exhausted` is a non-advancing predicate:
it is true only after the generator completes, and false for new, suspended,
and failed generators.
The final DEBUGGING `make_test` run completed 2,947 files and 1,398,115 tests.
All generator tests passed.  Its diagnostic failures were the four generator
messages added after that run began; a subsequent standalone diagnostic check
confirmed those messages are documented.  The only remaining version-check
notice is the generated `B::Op_private` file, whose version is tied to the
unchanged core Perl version.

Follow-up: consider blessing the callable generator CODE reference into an
`generator::Instance` class implemented in Perl, providing convenience methods
such as `next()` and `exhausted()` to callers that do not enable the generator
feature.  This should preserve the primitive callable protocol.
