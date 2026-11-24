# Execution suspension in XPerl

Audit baseline: `f97d2b8bd4`, 24 November 2026. This report distinguishes
the existing mechanism, the uncommitted lifecycle prototype, and possible future front ends.

Status: the whole-stack probes are confirmed. Lifecycle operations and
the common C interface described below are an uncommitted prototype.
The shared lexical-pad ownership bug is fixed separately in `7448c9af6c`;
see [Shared pad ownership](shared-pad-ownership.md). Other baseline defects
are identified below. This report does not propose shipping a permanent
fiber or async API yet.

## Confirmed baseline

The runtime saves a whole private Perl execution stack. It is not limited
to a single Perl subroutine frame. The generator compiler restricts the
`yield` syntax to a generator CV; that is a language restriction rather
than a limit of the saved context.

An independent probe on the baseline called a yielding leaf through two
ordinary named Perl subs. The first invocation yielded before those subs
returned. Later invocations supplied values to the leaf's suspended
expression. `caller` retained both named frames, and the intervening
arguments and lexical values survived. The final result was 95. The same
probe passed on the regular interpreter and a threaded, reference-counted
stack build with AddressSanitizer. The probe extracted the leaf's compiled
CV with `B` to bypass the syntax restriction. It did not add a suspension
mechanism.

### Creation and ownership

`gen` compiles an anonymous Perl CV with `CvGENERATOR`. Evaluating that
CV through `pp_anoncode` creates a callable XSUB wrapper. Magic on the
wrapper owns a C execution record, which owns a reference to the body CV.
Creating the wrapper does not execute the body.

On first execution the runtime obtains a private `PERL_SI` value/context
stack and allocates separate mark, save, scope, and temporary stacks. The
body is entered through an ordinary `OP_ENTERSUB`. Its Perl subroutine
frames consequently use normal context-stack and pad machinery.

The private `PERL_SI` is detached from the interpreter's stack chain while
suspended and relinked for execution or cleanup. After termination its
value stack returns to the interpreter's reusable stack pool. The
separately allocated auxiliary stacks belong to the execution record.
Copying `PERL_PROCESS_STATE` alone does not allocate or clone those stacks.

### What is saved

`PERL_EXECUTION_CONTEXT` is generated from the `PERLVARCTX` declarations in
`intrpvar.h`. `process_state_save` and `process_state_restore` transfer
those variables without copying the stack contents. The record covers:

- The current op, value stack, stack bounds, and `PERL_SI`. The latter
  contains the full Perl context stack.
- The active pad, compilation pad, current COP, stash, and debugger COP.
- The mark, save, scope, and mortal stacks, their positions, and capacities.
- Current regex match context, the enclosing regex context, and the
  multidereference cursor.
- The default glob, localization phase, eval flags, warning and taint
  state, delayed magic, and pending restart op.

The generator separately swaps the default scalar and default argument
array. This is not a snapshot of the interpreter. Other package variables,
filehandles, symbol tables, external resources, and native code's private
state are shared.

Debugging scope names need their own array alongside the private scope
stack. The baseline kept the caller's name array installed, so generator
execution could overwrite labels which the caller later checked. The
separate scope-name fix saves that pointer with the context and allocates
and frees private names together with private scope storage.

In particular, saving the save stack does not undo and reapply arbitrary
`local` entries on each switch. A caller can observe a paused generator's
`local $Package::variable`; a caller assignment affects what that generator
subsequently sees. The baseline's `local $@` has this limitation too.
This matters when designing independent tasks or fibers.

### Native frames and exception environments

The saved record contains no C stack and no `JMPENV`. Exception jump
environments are C activations. A fresh guard must be installed on every
resume, and suspended Perl eval/try frames must refer to the fresh guard.

An ordinary Perl call usually adds a Perl context rather than another C
run loop. Those frames can be parked together. XS, regex callbacks, sort,
overloading, tied operations, and other callbacks from native code may
instead leave a live C activation below the currently executing Perl op.
They cannot be parked and subsequently resumed by this mechanism.

The existing sort test is an example of deferred notification. Its
comparator completes, then its native sort operation returns, before the
owner exposes the requested yield. That is not suspension inside the
comparator. The comparator's local exception handler has ceased to exist
by the time the owner can resume.

Neither stack identity nor jump-environment identity alone proves that
there is no intervening native activation. A native callback can start a
second run loop on the same Perl stack. The reliable boundary is the return
from the pp function dispatched by the owning run loop.

The generator's completion hook now belongs to that owning run loop.
Nested debugging run loops no longer receive it through the global hook.
This fixes `threads->create` calling `CLONE_SKIP` inside a generator: the
callback's return was mistaken for completion of the whole generator.
It does not make native callbacks suspendable. The direct yield path's
stack-identity check remains a separate limitation for same-stack native
callbacks which themselves attempt to yield.

### Baseline defects found during this audit

- An eval spanning a yield did not reliably catch a later exception. The
  resume guard treated the restart jump as terminal instead of executing
  the saved handler op.
- Escaping user-reference exceptions crossed the generator boundary using
  `$@` rather than the canonical exception. This could replace the canonical
  wrapper with its compatibility value.
- Destroying an abandoned generator performed `dounwind`, but without
  swapping in its default-variable state. Cleanup could see or damage the
  caller's topic.
- An explicit `return` in an ordinary helper could mark the entire
  generator as explicitly returning. This affected an eventual implicit
  undefined result.

Normal abandonment already attempted a scope unwind; it was not merely
freeing a saved byte buffer. Global interpreter destruction is a separate
path: active stacks are being dismantled, and the generator links its
private stack back for interpreter teardown rather than executing an
ordinary resumable unwind there.

## Draft common execution interface

`PERL_EXECUTION` owns the suspended execution. `PERL_GENERATOR` remains a
compatibility typedef. The generator's callable wrapper is a separate
front end. The common C operations are:

| Operation | Purpose |
| --- | --- |
| `execution_new(body)` | Create an unstarted context owning a Perl CV |
| `execution_resume(context, args)` | Start or resume with values |
| `execution_suspend_values(values, count)` | Request suspension and outgoing values |
| `execution_throw(context, exception)` | Raise at an exact suspended yield expression |
| `execution_close(context)` | Unwind and terminate without continuing ordinary body code |
| `execution_state(context)` | Inspect lifecycle state without running code |
| `execution_free(context)` | Release ownership, closing an abandoned context first |

The existing `generator_*` C entry points delegate to the same backend.
There is no future, scheduler, event loop, or I/O dependency in these
operations. This remains an internal interface. Its existing generator
state constants and dynamic call-context policy are retained for
compatibility; a future front end should choose its result context
explicitly rather than assume generator `wantarray` policy is universal.

### Safe suspension

The owning execution loop commits a suspension after its dispatched pp
function returns. A direct `OP_YIELD` is an exact suspension point, with
the full intervening Perl call chain saved. A notification originating in
a nested native callback is deferred until that native operation returns.
The context records which kind occurred.

Exceptional resumption requires an exact yield point. It cannot raise an
exception inside a comparator or callback which has already returned.
Deferred notifications cannot receive values back into the finished
callback. Existing deferred sort notification remains available.

Ordinary opcode dispatch contains no suspension or async-state check.
Only the explicitly selected execution loop inspects suspension requests.
The generic opcode-boundary scheduler experiment remains distinct from
this owner-controlled execution loop.

### Exceptions and cleanup

Each resume establishes a fresh exception environment. A caught exception
restarts the innermost live Perl handler through its `PL_restartop`.
An uncaught exception crosses the execution boundary as the canonical
`XPerl::Exception`, retaining user-reference compatibility and avoiding a
second delivery through exception hooks.

Execution contexts now explicitly retain their `$@` and canonical error
slots alongside their default-variable state. A successful resume or close
restores the caller's error state. This addresses these particular slots;
it does not implement arbitrary dynamic-variable isolation.

`throw` performs normal exception delivery inside the restored context.
The body may catch the exception, yield, return, or let it escape. It does
not promise termination.

`close` marks the context closing before cleanup. It unwinds Perl scopes,
runs lexical destruction and registered defer/finally handlers, and
restores localized values. Parked body handlers are disabled during that
unwind, so a cleanup exception cannot enter an abandoned body catch.
New handlers established inside cleanup work normally. Remaining scopes are unwound before the escaping cleanup exception is
reported to the caller. Ordinary Perl unwind rules may replace an earlier
cleanup exception with a later one before the execution owner regains
control. The prototype is being checked against those rules.

Close is idempotent. Closing an unstarted context does not run its body.
A running or already-closing context rejects reentrant close. Yielding
during close is invalid. Explicitly closed contexts cannot resume, and
closure is distinguishable from normal completion and failure. Closing
an already completed or failed context retains that terminal outcome.

Close releases the context's saved values, arguments, body, and snapshots,
even when the wrapper remains referenced. Values already retained by an
external adapter or another owner remain that owner's responsibility.
Closing a context can break its body/wrapper reference cycle. A cycle which
is never explicitly closed retains ordinary Perl reference-counting
limitations. During global interpreter destruction, the special stack
teardown path remains necessary; applications needing ordinary cleanup
should close their contexts before that phase.

## Async/await and fiber recommendations

The existing private Perl stack preserves a cooperative call chain rooted
at an explicit execution owner. Independent scheduling additionally needs
correct activation-pad ownership, which the existing runtime lacks. It does not capture the
caller's stack below that owner. A public fiber suspension operation could
compile to the same explicit suspension op without requiring the
generator-only syntax restriction.

Before exposing that API, fix shared activation-pad ownership and decide how to handle native callback requests:
reject them as suspension barriers, or expose deferred notification with
its weaker semantics. Do not present a deferred callback as a resumable
continuation. Full preservation of native activations would require a
different architecture, not another saved Perl context field.

Conventional async/await does not require preserving arbitrary native
activations, but concurrent invocations still need independent live pads. An async front end can own an execution context, suspend at
an explicit await operation, and return control to its driver. On
completion of the awaited operation, the driver supplies values or calls
exceptional resumption. Futures and event loops belong to that front end.

Cancellation can request an exception, allowing application policy to
handle it, or explicitly close the context to unwind it. These operations
must remain distinct. Neither introduces a scheduler poll in ordinary
subroutines.

Dynamic localization is a separate design decision for fibers. Options
include a deliberately shared dynamic environment, compiler restrictions
around awaits, or additional machinery to switch selected dynamic state.
This change does not claim fully isolated general-purpose fibers.

## Validation and measurements

Validation and before/after benchmark results are recorded here after the
runtime and lifecycle tests complete. `Porting/bench-suspension` measures
arithmetic loop iterations, ordinary calls, context creation, first
suspension, resumption, and destruction separately. The arithmetic case
includes loop control; it is not a measurement of one isolated opcode.
