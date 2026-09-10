# Constraint-first matching and capture ownership

## Agreed behavior

Check structural prerequisites and literal constraints before capture-only
reads, including for magical values. Preserve leftmost candidate selection
and run guards only after structural success and pad publication. A rejected
guard advances to the next clause. Cache observations rather than repeating
callbacks during capture collection.

Use a lazy mortal AV as an append-only owner. Binding records hold indices;
ordinary values are retained, not snapshotted. Tail elements remain copies.
Keep retention versus snapshotting under the existing copy/alias decision.
Retain containers across callbacks; use initial array candidate bounds and
live subsequent reads. Missing array slots are undef; missing keys are absent.

## Implementation stages

1. COMPLETE (initial stage): Regression tests, indexed AV ownership,
   exception-safe publication storage and traversal retention. Threaded
   DEBUGGING focused suite passes 417 tests. The initial reservation uses
   the existing clause capacity; enclosing-case reservation follows with
   compiled scheduling metadata. Sanitizer validation remains outstanding.
2. IMPLEMENTED: Compiled constraint ranks and deferred capture locations,
   including nested shapes, repeated bindings and cached regex observations.
   Enclosing-case capacity is now used for initial owner reservation.
3. IN PROGRESS: Update user docs/deltas and validate focused, porting, full, threaded,
   nonthreaded and sanitizer suites. Record exact configurations and results.

The HV numeric-domain issue remains deferred. No parser syntax changes are
planned. Keep stages in incremental buildable commits. Presizing is a
reservation, not a limit; append paths must safely handle growth and overflow.
