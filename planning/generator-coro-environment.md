# Generator environment and localization

This is the current support report for the localization prototype on
`xperl/proto-localize`. It is not a claim about XPerl main. The Coro 6.57
state list helped identify interpreter settings which live outside the
execution stacks. XPerl does not implement Coro's native C stack switching.

## What works

A generator can run `local $x = 'owner'`, yield, and later resume with the
same localized scalar. Between calls the caller sees its own binding.
References keep pointing to their original scalars. The generator can
finish or be abandoned independently of other generators using `$x`.

The prototype supports:

* Ordinary package scalar, whole-array and whole-hash locals, including
  nested locals, references and ordinary glob alias merges and splits.
  The scalar case requires non-magical storage. Arrays retain their core
  iteration, length-reference and weak-reference bookkeeping.
* Ordinary package variables used as `foreach` iterators. The iterator
  keeps its alias to the actual loop element, rather than copying a value.
* Lexical loop variables and the implicit topic bindings of `foreach`,
  `map` and `grep`.
* Localized `%SIG` entries, including the warning and exception hooks.
  Native signal handling needs `sigaction` and `sigprocmask` support.
* The existing independent `$_`, `@_`, `$@` and `${^ERROR_OBJ}` bindings.
  Explicit `local $_` joins ordered scalar replay when no implicit topic
  scope is active. Caller-created aliases then expose the innermost local
  during execution and cleanup.

Input separators, selected output handles and compiler hints are kept with
an owner's execution stacks, following Coro's approach. They start with
XPerl's creator settings. The separator includes both the Perl scalar and
its input machinery. Selecting an output handle preserves that selection,
not a private copy of the underlying file. Compiler, parser, sort and
runloop pointers move with the execution context. This does not preserve
an active native compiler or sort call frame.

The owner removes its locals in reverse order before yielding. It
reinstalls them in forward order on resumption. Ordinary scope exit really
restores and releases them. Abandonment reinstalls the environment before
running the owner's cleanup.

`local @array` and `local %hash` exchange the named glob's array or hash
binding, just as `local $scalar` exchanges its scalar binding. Each owner
keeps the actual AV or HV. References and iterator positions continue to
belong to that object; no aggregate contents are copied during switching.
The slots are independent even when a scalar, array and hash share one
global name. Real scope exit keeps ordinary Perl's destruction order.

## Signal handlers follow local

For example, a generator running `local $SIG{WINCH} = $handler` sees its
handler while it runs. After yield, the caller's handler is installed.
On resume, the owner's handler returns. If the caller changed its handler
while the owner was parked, completion restores that newer handler.
Nested owners follow the same rule.

An ordinary assignment to `$SIG{WINCH}` remains global. Creating a
generator neither clones `%SIG` nor gives it private signal handlers.
The journal is created only when an owner actually localizes an entry.
It records those keys, including whether they were absent or undefined.
It preserves the scalar bindings and the effective handlers separately:
alternate signal names can share a native handler, and reading one name
can refresh its scalar from that shared handler.

On supported platforms, the saved native state includes the mask
and flags as well as the handler. The exchange blocks signals while moving
that state and Perl's handler references. It calls no set-magic or signal
callbacks. Pending signals stay shared. This is cooperative interpreter
state switching, not isolation from other native threads changing process
signal actions. Unmasking can deliver a pending signal before the rest of
the context switch has finished. Unsafe signal callbacks must not assume
that the whole execution context has already moved.

The physical hash exposes the active bindings on access. A context switch
moves the saved bindings without allocating hash entries. An explicit hash
operation can then allocate to expose an absent or newly present key.
Departing bindings release matching cache references while the journal
still owns the scalars, so this step cannot destroy a handler. `%SIG` key
order and iterator position are not preserved across context switches.

## What is not isolated

* Whole globs and special aggregates needing additional handling. A live
  `local %SIG`, `local %ENV`, `local @ISA` or symbol-table localization
  prevents suspension. Tied arrays and hashes cannot cross a yield either.
  The managed `@_` and `%^H` roots keep their existing environment handling;
  aliases overlapping their slots are not separately replayed.
* Ordinary array and hash element locals cannot cross a yield. Their
  save entries retain shared storage which we cannot yet put aside and
  safely reinstall. This includes elements of lexical aggregates: the
  check does not try to prove that an aggregate has no outside references.
  `%SIG` entries have their own handling as described above.
* Direct `delete local $SIG{...}` is not generally suspendable. Its
  existing synchronous behavior is preserved, including the returned
  scalar's identity. Use `local $SIG{...}; delete $SIG{...};` when the
  owner needs to suspend with the key absent.
* Tied signal hashes and native signal locals without a supported native
  backend cannot cross a yield. Tie callbacks do not run during a switch.
* Other magical package scalar locals and external effects such as `%ENV`.
* Special named loop aliases which overlap the error roots. These reject
  suspension rather than leave an untracked alias for later cleanup.

An ordinary helper can use local variables and return before a generator
yields. Its localizations have already ended at that point. With the
current lexical `yield`, active locals which prevent suspension are in
the generator body, including its nested blocks. A parked owner whose
aggregate was subsequently tied cannot resume until that conflict is
removed. Validation happens before any binding exchange.

Yield checks the owner's active save entries, including when there are no
ordinary package locals to replay. It permits supported bindings, private
execution state and known cleanup operations. An unhandled entry throws
before anything is detached. The generator can catch the exception, leave
the offending scope and yield again. We do not inspect the caller's save
stack, ban local inside ordinary helper calls or add opcode dispatch checks.
The [yield check report](generator-yield-localization.md) records the save
classification, topic-alias handling and suspension costs.

Some unsupported alias overlaps retain the prototype's discard fallback.
Rejecting resume does not establish complete destructor visibility for
those cases. Aliasing the topic to another managed interpreter root can
also change which root value the owner observes. See the
[scalar alias report](reversible-localization-aliases.md).

Saving Perl frames does not preserve native C frames. Public `yield`
remains lexical to a generator. Sort, regex and XS callbacks cannot suspend
an active native caller. This work adds no async or fiber API.

## Cost and validation

Ordinary opcode dispatch, subroutine entry and scalar access gain no
checks. Some hash operations check for signal magic when a journal exists.
Switching scans the owner's save records and loop contexts, then
exchanges its tracked bindings. Native signal actions add system calls
only when signal locals are active. Signal journal records retain their
native mask storage, so switching needs no fresh mask allocation.

Regression coverage lives in `t/op/generator_environment.t`,
`t/op/generator_loop_local.t`, `t/op/generator_aggregate_local.t` and
`t/op/generator_sig_local.t`, alongside
the existing context, cleanup and randomized-localization tests. The signal
checks include actual delivery, nested locals, caller edits, abandonment,
missing keys, alternate signal names and POSIX action masks and flags.
Earlier scalar measurements do not measure this extension.

Validation on 2026-11-26 passed the full optimized, unthreaded test suite.
The generator suites also passed with threads, debugging and reference-counted
stacks, and in an unthreaded debugging build with AddressSanitizer and leak
detection. Leak checks used `PERL_DESTRUCT_LEVEL=2`. These builds produced no
compiler warnings. Generated-file and diagnostic checks passed after full
regeneration.

On 2026-11-26, the optimized unthreaded build took about 0.26 microseconds
per empty suspend/resume pair, compared with 0.24 before this extension.
One active package iterator took 0.33 microseconds, and one native signal
local took 1.11 microseconds. The latter includes signal-action system
calls. Creating and destroying an unstarted generator rose from 0.32 to
0.70 microseconds because creation now saves additional settings.

The existing localization benchmark measured 1.47 versus 1.66 microseconds
with 32 distinct scalar locals, and 9.83 versus 12.00 with 256. Switching
remains linear in the saved state but does more bookkeeping. Ordinary
localization measured 41 nanoseconds in both runs of that benchmark.
These are medians from nine samples on one Linux x86_64 host, with matching
unthreaded `-O3` builds. They do not demonstrate a synchronous speedup.
[Raw samples and configuration](generator-coro-environment-benchmarks.json)
include the baseline commit and measurement protocol. The scalar workloads
come from `Porting/bench-generator-local`. The other cases are retained in
[`generator-coro-environment-bench.pl`](generator-coro-environment-bench.pl),
run from the checkout root with `./perl -Ilib`, followed by `before` or
`after`.

Whole aggregate support was measured separately on the same date using
matching threaded debugging builds with reference-counted stacks and
`-O3 -g`. These figures are not directly comparable to the unthreaded
environment timings above. Each localized aggregate contained one initial
element or key. Medians came from nine samples of 10,000 resume/yield pairs.

| Active local bindings | Before, microseconds per pair | After, microseconds per pair |
| --- | ---: | ---: |
| None | 0.52 | 0.54 |
| 32 scalar locals | 1.91 | 2.69 |
| 32 array locals | 0.50 | 3.03 |
| 64 array locals | 0.64 | 5.55 |
| 32 hash locals | 1.30 | 3.30 |
| 64 hash locals | 2.13 | 5.83 |

The earlier array/hash implementation did not isolate the bindings. Its
lower times omit the work needed for correctness. The new costs grow with
the number of saved bindings, without copying their contents. Scalar
switching gains additional slot classification. Ordinary call, access and
localization paths have no new checks, but control timings varied in both
directions; these samples do not establish unchanged ordinary performance.
The [measurement script](generator-aggregate-local-bench.pl) and
[raw samples](generator-aggregate-local-benchmarks.json) retain the build
configuration and baseline commit.

The whole-aggregate extension passed the full regular suite and focused
generator checks on the threaded reference-counted debugging build and
the unthreaded ASan/LSan build. Its regression cases cover current-caller
restoration, aliases, absent slots, iterator and reference identities,
cleanup order, randomized interleaving and unsupported special bindings.
