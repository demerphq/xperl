# Checking localizations at yield

A generator may use `local`. It may suspend only when we know how to put
aside every localization still in scope. For example, `local $Package::x`
can cross a yield, but `local $hash{key}` cannot. The latter retains an
aggregate element which outside code may delete or replace while the
owner is parked. We do not yet have a safe reversible binding for it.

The check runs at explicit yield, before detaching pads or bindings. It
scans only the owner's active save records and execution contexts. A
failure throws a structured generator exception. Nothing has been put
aside at that point, so the body can catch the exception, finish that
scope and yield again. Returning from the body does not require its locals
to be suspendable.

Ordinary helper calls remain free to localize elements and globs. Their
locals have already unwound when execution returns to the lexical yield
in the generator body. The caller's locals live on a different save stack
and are not part of the check.

## What the check recognizes

| Active state | Treatment |
| --- | --- |
| Ordinary package scalar, whole array or whole hash local | Existing replay checks establish that the actual binding can move |
| Canonical topic, arguments, error roots, input separator and hints | Existing owner environment handles these roots |
| Supported individual signal handler local | Signal journal moves the binding and effective native handler |
| Package or lexical foreach iterator | Existing iterator handling preserves its alias |
| Implicit map or grep topic | Recognize the core's paired topic save |
| Pointer or numeric restoration | Admit only targets explicitly kept with the owner |
| Lexical pad and temporary cleanup | Retain for ordinary scope exit |
| Defer and finally cleanup | Explicitly marked by their producer; retain for scope exit |
| Array/hash element, whole glob or arbitrary glob-slot local | Reject suspension |
| Unknown pointer destination, opaque restoration callback or unhandled save tag | Reject suspension |

The check does not infer ownership merely because an entry contains a
pointer. Some save entries name interpreter fields which move with the
execution context. Others name shared objects or native C stack storage.
Their tag can be identical. Unknown callbacks can restore signal masks or
other external state, so they are not assumed to be harmless cleanup.

Element rejection includes lexical aggregates. A lexical name alone does
not prove that outside code has no reference to its contents. The existing
signal journal provides the narrowly supported element exception.

## Cost and boundaries

The scan is linear in the active owner save-stack depth and context depth.
It allocates no journal and executes no restoration callbacks. Replay has
its own eligibility checks before exchanging bindings. Ordinary subroutine
entry, localization, variable access and opcode dispatch gain no checks.

This is a guard for the existing generator suspension boundary. It does
not preserve native C frames or make otherwise unsafe nested runloops
suspendable. Future suspension operations would need to use the same
validation boundary, including active locals in intervening Perl calls.

See [the support report](generator-coro-environment.md) for the current
binding and signal limitations. Measurements and validation results follow.

## Measurements

These are same-host Linux measurements from 2026-11-26, with ithreads,
DEBUGGING and reference-counted stacks, compiled with `-O3 -g`. The baseline
rebuilds the parent's `run.c`, `scope.c` and `pp_ctl.c` in a copy of the final
build. Generated headers and extensions are identical, which keeps the
comparison focused on this change. It is not a separate historical build.

The benchmark uses process CPU time, an untimed warm-up and the median of
repeated samples. Suspension measures a resume through the next yield.
Each sample performs 10,000 operations. Times below are microseconds per
operation. A larger after/before ratio means slower execution.

| Operation | Before | After | After/before |
| --- | ---: | ---: | ---: |
| Ordinary scalar read | 0.073 | 0.077 | 1.06 |
| Ordinary subroutine call | 0.285 | 0.313 | 1.10 |
| Ordinary scalar local | 0.205 | 0.222 | 1.08 |
| Suspend without package locals | 1.250 | 1.403 | 1.12 |
| Suspend with 64 scalar locals | 9.455 | 13.057 | 1.38 |
| Suspend with 64 array locals | 12.462 | 16.755 | 1.34 |
| Suspend with 64 hash locals | 13.074 | 17.184 | 1.31 |

The safety scan adds work proportional to active save entries. These
measurements show a noticeable cost for wide active scopes. The unchanged
ordinary operations vary too, so the ratios are approximate observations,
not precise overhead estimates. Other validation jobs were running on the
host. CPU time avoids charging their time slices to the benchmark, but
does not remove cache and CPU frequency effects.

The [benchmark](generator-yield-localization-bench.pl) and
[raw samples](generator-yield-localization-bench.json) include the smaller
scope sizes. The implementation adds no checks to ordinary subroutine
entry, scalar localization, variable access or opcode dispatch.

## Validation

The generator suite passes on the regular optimized build, the threaded
DEBUGGING build with reference-counted stacks, and the DEBUGGING address
sanitizer build. Leak checks use `PERL_DESTRUCT_LEVEL=2` and enable LSan.
The build logs contain no compiler warnings.

Coverage includes rejected yield with no replay journal, caught rejection
followed by a valid yield, unchanged binding identities after rejection,
helper and caller locals, normal return, tied elements, reference-alias
loops, pending defer/finally cleanup and parked map/grep topic aliases.
The existing randomized owner interleavings pass in these configurations.

The final regular full test suite passes, including regeneration, manifest,
version and argument-assertion checks. An earlier run found the new helper's
missing assertion-macro invocation; that was corrected before the final run.
