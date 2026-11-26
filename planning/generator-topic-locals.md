# Explicit topic locals and changed aliases

A generator can localize `$_` and an ordinary package scalar, then pause.
If its caller aliases those names while it is parked, both names must
observe the innermost local when the owner runs again. Ordinary Perl
localization establishes that order.

Previously, only the ordinary scalar joined ordered replay. The explicit
topic local stayed under the generator's default-variable handling. Resume
rejected the overlap. Abandonment then skipped ordinary scalar replay, so
a destructor could see the outer topic instead of the inner scalar. The
caller kept its binding, but the owner's cleanup saw the wrong value.

Explicit topic locals now share the scalar replay order. Suspension removes
them in reverse order; resume and abandonment reinstall them in forward
order. The default environment holds the underlying topic binding after
those locals have been removed. References retain their original scalars.
The caller receives its current binding back after the owner stops running.

## Preserve ordinary scope exit

Real scope exit uses Perl's existing scalar restoration for a saved topic.
That retains its magic behavior and destruction order. A prior alias merge
or split can also leave an absent outside slot. The reversible scalar path
already supports restoring that absence without creating a replacement SV.

No new save tag or public API is needed. The existing scalar
record owns the same references as an ordinary topic save. The extra work
occurs at execution boundaries and generator scope exit.

## Boundaries

Implicit topics from `map`, `grep`, canonical foreach, `given` and unnamed
`dispatch` keep their existing handling. An explicit local can suspend
before, inside and after one of those constructs without losing its value.
Supporting an additional overlapping scalar alias inside such an implicit
scope remains separate work. Resume rejects that conflict rather than
replaying records in the wrong order.

Error variables and the input separator have additional interpreter state.
A topic local cannot replay through those roots. The input separator check
uses the glob retained by the generator as well as the current symbol-table
entry. Outside code can delete and recreate that symbol; looking up only
its current entry would miss an alias to the original glob and let `$/`
disagree with what `readline` actually uses. Removing the conflicting alias
allows the owner to resume.

Checking a replacement stash entry must leave it unchanged. A lookup with
zero flags can expand a stored coderef into a glob, so validation explicitly
requests an existing, uninitialized entry and checks its type before using
it as a glob.

Unsupported overlaps can still take the documented discard path during
abandonment. This change fixes explicit topic/scalar ordering; it does not
promise a complete cleanup environment for every unsupported root alias.
The [support report](generator-coro-environment.md) describes those limits.

## Validation

The regression compares both declaration orders with an ordinary Perl
control under the same alias topology. It checks values and scalar
identities on return, failure and abandonment, including abandonment before
any attempted resume. Randomized interleavings change the caller's aliases
between activations of owners sharing body CVs.

Other cases cover nested implicit topics, tied topic restoration without
switch-time tie callbacks, an absent outside slot after alias splitting,
and replacement of the input separator's symbol-table entry. The separator
regression checks rejection, unchanged caller identity and successful retry
with the scalar value and `readline` result in agreement.

The regular full suite passes, including regeneration, argument assertions,
manifest and version checks. The generator suite also passes with threads,
DEBUGGING and reference-counted stacks, and in the regular-stack DEBUGGING
ASan build with LSan enabled and `PERL_DESTRUCT_LEVEL=2`. The build logs
contain no compiler warnings.

## Suspension cost

Measurements on 2026-11-26 compare parent `991a91b2a5` with this change on
one Linux host. Both builds use ithreads, DEBUGGING, reference-counted
stacks and `-O3 -g`. The processes are pinned to CPU 0 with identical hash
seeds after the other validation jobs finish. The table gives the median
process CPU time from nine samples of 10,000 resume/yield pairs, after
an untimed warm-up. A larger after/before ratio means slower execution.

| Nested explicit topic locals | Before (microseconds) | After (microseconds) | After/before |
| ---: | ---: | ---: | ---: |
| 0 | 0.412 | 0.380 | 0.92 |
| 1 | 0.426 | 0.689 | 1.62 |
| 8 | 0.496 | 1.777 | 3.58 |
| 32 | 0.727 | 5.150 | 7.08 |

The old root-only handling was cheaper because it did not replay these
locals. The new cost grows with the explicit localizations that must be
recorded and exchanged. The empty control varies slightly; it does not
establish a speedup. Ordinary subroutine entry and opcode dispatch gain
no checks. These are debugging-build measurements, not release-build
latency guarantees.

The [benchmark](generator-topic-local-bench.pl) and
[raw samples](generator-topic-local-bench.json) retain the configuration
and process CPU timings. Earlier runs made during concurrent builds were
discarded because even the empty control changed substantially.
