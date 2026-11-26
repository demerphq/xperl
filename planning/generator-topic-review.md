# Fresh review of topic localization and boundary checks

Astra reviewed `df62eb40c1` again after it was committed. The fresh review
found a new validation side effect and earlier prototype problems. The
ordering and ownership checks passed the independent controls described
below. Those results do not make every glob or special-variable alias
supported.

## What the review found

The new topic check could expand a coderef stored under `/` into a glob.
A zero-flag glob lookup can initialize an existing symbol-table entry.
Validation now requests a noninitializing lookup and checks the returned
type before reading glob fields. Fixup `66ea8f4bbd` records that correction.
The regression fails on the original commit and passes after the change.

The earlier yield guard had the same expanding lookup. It could also
reject a valid `local $/` after the caller replaced the symbol-table entry.
The guard now checks against the actual glob retained by that generator.
A replacement entry does not change which binding the owner switches.

Earlier hash and map checks could expand a coderef under `SIG` before a
signal journal existed. Both checks now use one noninitializing, type-checked
lookup. An existing retained signal glob takes priority. The correction
changes validation, not signal-handler installation or delivery.

An ordinary scalar or named foreach variable could be redirected to the
input-separator glob while its owner was parked. Replay then changed the
visible `$/` without changing the state used by `readline`. Scalar and
iterator records now reject that overlap on suspension or resume. The
checks cover both the retained separator and a new current glob. Removing
the conflicting caller alias permits retry. Array and hash slots keep
their distinct eligibility rules.

## Independent checks

Astra compared generator return and abandonment with ordinary Perl scope
exit under nested localizations and changed aliases. The checks included
multiple names, explicit topics, package foreach bindings and active-owner
glob changes. Values, scalar identities, cleanup order and caller bindings
matched the controls.

Separate probes resumed or abandoned a child while its parent had different
localization order and alias relationships. Another resumed a child from
an outgoing topic object's destructor. The restored outer topic and the
caller's identities survived those callbacks.

Astra's bounded source review approved the resulting root checks and their
regressions. Its additional runtime investigation was stopped by an automated
filter. The completed independent comparison results remain useful; final
runtime validation of the corrections is performed separately on this branch.

## Namespace fixtures and a separate native failure

Namespace replacement cases run in fresh interpreters. Glob localization
does not by itself undo every subsequent replacement of a stash entry.
Sharing those changes between cases would make later symbol lookups depend
on earlier fixtures.

A separate control also fails in ordinary subroutines, without executing
any generators: localize the `SIG` stash entry, replace it with a coderef,
call ordinary code, and repeat. The saved debugging interpreter at `66ea8f4bbd`
fails its `isGV` assertion in `Perl_save_gp`; the optimized interpreter
terminates there. This is recorded for separate investigation, rather than
changed as part of the generator checks.

The [ordinary localization control](probes/stash-localization-control.pl)
uses the checkout's test helpers. Run it from the checkout root. It currently
ends in the native localization failure, so it is a planning probe rather
than part of the passing regression suite.

The generator regressions independently check raw `SIG` entries, a retained
localized separator, initial scalar/iterator aliases, parked retargeting,
rejection, caller identities, abandonment and successful retry. Fresh cases
cover retained roots and newly created current roots without sharing modified
namespace entries.

Native signal syscall failures, every platform's interpreter-cloning path,
and complete destructor visibility for documented unsupported aliases remain
outside what these probes establish.

## Validation of the corrections

The full regular suite passes. The generator suite passes with threads,
DEBUGGING and reference-counted stacks, and with ASan/LSan enabled on the
regular stack. Leak runs use `PERL_DESTRUCT_LEVEL=2`. Exact source comparisons
precede the matrix builds. The build logs contain no compiler warnings.
The final namespace fixtures also pass on these configurations using a DATA
filehandle, without requiring the optional scalar-I/O layer. POD checks pass.

## Cost of checking scalar roots

Every boundary pass checks scalar and iterator slots against the current
separator and the one retained by the owner. Those lookups add work when
many ordinary scalars are localized. They do not run on ordinary variable
access or subroutine entry.

Same-host measurements on 2026-11-26 compare the saved `66ea8f4bbd` executable
with the correction. Both use ithreads, DEBUGGING, reference-counted stacks
and `-O3 -g`. Both processes are pinned to CPU 0 with identical hash seeds
after validation jobs finish. Times are medians from nine process-CPU samples
of 10,000 operations after a warm-up. A larger ratio means slower execution.

| Operation | Before (microseconds) | After (microseconds) | After/before |
| --- | ---: | ---: | ---: |
| Ordinary scalar read | 0.026 | 0.027 | 1.03 |
| Ordinary subroutine call | 0.083 | 0.081 | 0.98 |
| Ordinary scalar local | 0.064 | 0.064 | 1.00 |
| Resume/yield without locals | 0.446 | 0.439 | 0.98 |
| Resume/yield with 8 scalar locals | 1.087 | 1.734 | 1.60 |
| Resume/yield with 32 scalar locals | 2.733 | 5.117 | 1.87 |
| Resume/yield with 64 scalar locals | 5.365 | 9.569 | 1.78 |

The extra scalar checks have a measurable cost at suspension and resumption.
The controls vary slightly and do not establish a synchronous speedup. The
[raw data](generator-root-validation-bench.json) includes array/hash controls
and configuration. The benchmark is
[`generator-yield-localization-bench.pl`](generator-yield-localization-bench.pl).
