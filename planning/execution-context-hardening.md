# Execution-context correctness after the localization prototype

The scalar-localization prototype is on `xperl/proto-localize`. Its
ordered binding swaps avoid rescanning the whole save stack on every
resume. The next step is to make the existing execution boundaries safe
before supporting more kinds of localization. This work adds no public
generator, fiber or async API.

## Exception handling across suspension

An `eval` or `try` enclosing `yield` must catch an exception raised after
resumption. A native catch loop cannot survive suspension. The generator's
owning runloop now continues at the handler without creating that nested
loop. An escaping exception retains its original structured object.

Commit `e020fac913` contains this fix. Argument magic needs particular
care: fetching a resume argument can throw and unwind the generator's
lexical scopes before control reaches the handler. Both the argument
fetch and that unwind must run with the owner's default bindings.

## Binding identity and abandonment

Moving SV contents between headers changes what an escaped reference
sees while its owner is parked. We exchange the actual glob-slot bindings
instead. References, argument aliases and `foreach` aliases keep their
original SVs. The exchanges do not fetch or store tied values.

Each generator has independent `$@` and `${^ERROR_OBJ}` bindings. Its root
eval starts with empty error variables. Starting or resuming it preserves
the current caller's error bindings rather than retaining the original
caller's values.

Abandonment reinstalls the owner's bindings and pads before unwinding.
A live native exception guard catches failures from restoring a tied
local. Parked eval frames refer to that guard and have no continuation
address: cleanup must not run a handler in the abandoned program.

Destructors can grow the private stacks and create more temporaries.
Teardown drains the live value and mortal stacks before recording their
final addresses and releasing the arrays. The snapshot from the last
yield is insufficient for this job.

Restoration failures are retained separately. Combining them into the
original user exception would mutate that exception and needs special
care when several cleanups throw the same object. Deferred `misc`
warnings report each failure after the caller has been restored.
Reporting runs at the caller's scope exit, outside the wrapper's
free-magic callback. A throwing warning hook must not interrupt destruction
of that wrapper. Ordinary `DESTROY` exceptions follow Perl's existing
cleanup-warning path.

Commit `e7fb7ede42` contains the binding and guarded-cleanup fixes.
Regression coverage includes escaped references, initial and resumed
arguments, foreach aliases, tied topics, nested abandonment, throwing
restorations, repeated exceptions and throwing warning hooks. A copied-stack
interpreter clone also exercises a pending cleanup warning.

The scalar prototype additionally cancels a pending yield if its
localization checks fail and an owner-local handler catches the exception.
The rejected packet must not reach the caller before that handler runs.
Its references are released before the next successful suspension.

In the scalar prototype, the generic throwing-cleanup fixtures use tied array
elements. Magical package locals are deliberately rejected by the scalar
prototype. Element restoration exercises the same throwing cleanup path,
but does not establish isolation of element localizations while parked.

The focused suites passed on the normal build and on regular-stack and
threaded reference-counted DEBUGGING builds with ASan and LSan. Leak runs
used `PERL_DESTRUCT_LEVEL=2` outside a tracing process. The clone suite's
existing TODO for cloning inside BEGIN is unchanged.

## Reentrant argument cleanup

Replacing resume arguments happens in the resumer, before installing the
generator's private environment. Releasing an old argument can call its
`DESTROY`, which may invoke the same generator or clear the caller's last
reference to its wrapper.

The invocation keeps the wrapper CV alive through replacement and return.
The old argument field is cleared before releasing its values, and the
switching guard rejects recursive entry during replacement. Incoming
arguments have a typed owner on the resumer's save stack until their
transfer succeeds. They are released if cleanup exits instead. An `END`
block can subsequently resume the still-parked generator.

Regression coverage checks destructor reentry, destruction of the last
external wrapper reference, and exit while replacing arguments. The exit
fixtures also localize an ordinary package scalar so the prototype
exercises its binding records across suspension and exit.

## Boundary costs

These are relative measurements on one Linux host on 2026-11-25, using
the ordinary optimized build and `Porting/bench-generator-pads`. The
baseline is `e020fac913` with the initial cleanup-only default-variable
swaps, before guarded teardown and binding exchange. The candidate is
`e7fb7ede42`.

The first pair used 10,000 iterations and nine samples after a warm-up.
A repeat reversed the binary order and used 20,000 iterations and eleven
samples after a warm-up. The table gives the repeat's median nanoseconds
per operation. Raw samples from both pairs and build configuration are in
[the benchmark data](execution-context-hardening-bench.json).

| Operation | Before (ns) | After (ns) |
| --- | ---: | ---: |
| Ordinary call | 63.5 | 61.1 |
| Generator creation | 207.1 | 220.9 |
| Start and suspend | 801.2 | 906.6 |
| Resume and suspend across a batch of owners | 739.6 | 815.6 |
| Destroy suspended owner | 1390.3 | 1699.4 |
| Resume at call depth 0 | 251.6 | 244.9 |
| Resume at call depth 16 | 308.8 | 299.1 |
| Resume at call depth 64 | 458.7 | 448.8 |

Creation now allocates separate error scalars. Destruction establishes a
cleanup guard and drains live stacks. The batch measurements include a
larger collection of independently allocated owners. Repeated switching
of one owner at different depths is roughly unchanged. Control timings
varied between runs, so these figures do not establish precise percentage
changes or a speedup for ordinary calls.

## Process exit through private roots

The exit walker stops at each private execution root. Its native owner
finishes teardown, restores the caller and continues the existing exit
operation. Nested owners repeat this procedure. Each owner releases its
arguments and saved values before `END`, even if a global retains its
terminal wrapper. Final mortal release uses the same guarded unwind as
abandonment.

Previously the exit walker could pop into a caller's stackinfo while still
using the generator's save, scope and mortal stacks. An `exit` in a body
could enter repeated `panic: POPSTACK` failures. Abandonment could preserve
the exit status while leaking the generator's resources.

The private-root marker uses its own stack type. Exception-hook stacks
have a different type and must be unwound as callbacks. `PL_mainstack`
continues to identify the real interpreter main stack. The extra work is
confined to process exit and execution boundaries.

The exit regressions cover initial and resumed calls, nested owners,
sort and XS callbacks, exception hooks, evals, abandonment, retained
wrappers, exit statuses and resource destruction before `END`. The status
expectations come from ordinary `exit` controls on the same interpreter.
VMS controls and child programs use the same `vmsish hushed` setting.

Copied-stack interpreter cloning rejects an active private root before
allocating a target interpreter or visiting clone hooks. Perl frames do
not include the native owner guard, the resumer's saved state or the
generator's invocation return target. Clearing a copied marker would not
repair those missing pieces. Windows emulated fork performs the preflight
before allocating its child parameters or host. Direct cloning APIs retain
their own preflight. Ordinary thread creation and cloning after an owner
has parked remain available.

Native Windows and VMS runs were not available here. Their paths were
reviewed, and the Windows-only regression checks that a caught rejection
can be followed by an ordinary emulated fork outside the generator.

### Existing exit and later-cleanup interaction

The private-root fix does not redefine process exit during ordinary
destructor or deferred-warning cleanup. A separate control on unmodified
XPerl main reproduced this case without generators: a destructor requests
exit 23, then a deferred warning hook requests exit 37. `END` sees 37,
while the process returns 23. A dying hook can instead reach a caller's
eval while the process ultimately returns 23. This broader cleanup and
status-precedence problem needs separate work.

## Current glob aliases and remaining overlaps

Ordinary scalar restoration follows the glob's current scalar slot. The
prototype now follows that rule when the caller or owner merges or splits
aliases. The inner local can hide the outer one through both names. It
need not preserve the original alias layout. Earlier proposals to freeze
that layout or introduce new slot representations imposed a stronger
requirement than Perl itself.

The [alias assessment](reversible-localization-aliases.md) explains the
reference behavior and its identity checks. Validation now checks the
owner's saved scopes for unsupported overlap under the current aliases.
It does not reject an ordinary merge or split by itself.

Ordinary aliases to the topic use the owner's default bindings as the
outside environment for scalar replay. The defaults are installed first
on resume and abandonment, and removed last on suspension. This preserves
the scalar and caller argument-array identities even when their GPs are
shared.

Overlapping owner-side glob or topic saves and aliases to the error
bindings still need separate handling. An owner-side merge which
relocates an opaque saved caller binding can also exceed the prototype's
plain-binding checks. The discard fallback remains a limitation in those
unsupported cases, including destructor visibility. It is no longer the
cleanup path for ordinary alias changes.

## Ordinary execution

The changes operate at creation, entry, suspension and teardown boundaries.
They add no opcode-dispatch check, ordinary-subroutine entry check,
ordinary-localization bookkeeping or variable-access lookup.

They do not isolate deliberate writes through an escaped reference to
another context's error scalar. `$@` magic can affect the current canonical
error variable, as it can with ordinary localization of the error variables.
Context switching preserves bindings rather than forbidding communication
through shared references.
