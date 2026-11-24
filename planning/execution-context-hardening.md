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

The focused suites passed on the normal build and on regular-stack and
threaded reference-counted DEBUGGING builds with ASan and LSan. Leak runs
used `PERL_DESTRUCT_LEVEL=2` outside a tracing process. The clone suite's
existing TODO for cloning inside BEGIN is unchanged.

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

## Unresolved process exit

Process exit needs a separate fix. The existing exit walker pops toward
the interpreter's main stack before returning to a generator's native
guard. Popping a stackinfo does not switch its independently owned save,
scope and mortal stacks.

An `exit` in a generator body can consequently enter repeated
`panic: POPSTACK` failures. An `exit` during abandonment can reach `END`
with the right status while retaining resources owned by the generator.
Neither behavior is fixed by catching ordinary cleanup exceptions.

The proposed fix is to mark each private root stackinfo. The exit walker
would stop at the nearest such root, let its owner finish teardown, then
continue exit in the restored caller with the original process status.
Nested owners would repeat this procedure. This adds work to process exit
and execution boundaries, with no check in ordinary opcode dispatch.

Validation must check status, `END`'s environment, resource destruction,
nested owners and native callbacks on both stack configurations. Do not
replace `PL_mainstack` temporarily: interpreter cloning uses it as the
actual interpreter main stack.

## Unresolved glob-alias changes

The prototype's fallback after incompatible glob-alias changes preserves
the caller but runs cleanup in the wrong scalar environment. It is not a
general solution. The [alias assessment](reversible-localization-aliases.md)
explains why retaining an old GP does not preserve both scalar aliases and
the caller's unlocalized array bindings.

Rejecting incompatible assignments alone is insufficient. Leaving an
already-open `local *glob` scope can change the alias relationships while
an owner is parked. A restriction would have to cover pending restorations
as well as new assignments. Alternatively, independently rebindable scalar
slots need a separate representation design. No such policy or
representation change is implemented here.

## Ordinary execution

The changes operate at creation, entry, suspension and teardown boundaries.
They add no opcode-dispatch check, ordinary-subroutine entry check,
ordinary-localization bookkeeping or variable-access lookup.

They do not isolate deliberate writes through an escaped reference to
another context's error scalar. `$@` magic can affect the current canonical
error variable, as it can with ordinary localization of the error variables.
Context switching preserves bindings rather than forbidding communication
through shared references.
