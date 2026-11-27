# Async tasks on the existing execution stacks

This prototype builds async tasks on the execution machinery used by
generators. It adds a task interface and a small default driver. It does
not copy native C stacks or introduce scheduling into ordinary opcode
dispatch.

## What a program does

```perl
use async;
no warnings 'experimental::builtin';

sub wait_for_result ($task) { return await $task }

async sub child ($value) {
    await XPerl::Task->delay(0);
    return $value + 1;
}

async sub main () {
    my $a = child(20);
    my $b = child(21);
    return wait_for_result($a) + wait_for_result($b);
}

print run(main()), "\n"; # 43
```

An async call creates an `XPerl::Task`. The driver starts its execution in
scalar context. An unfinished await parks the whole Perl call chain,
including ordinary helper calls. The dependency's eventual value or
exception is delivered at that await. Helpers need no async declaration.

`use xperl` enables the feature and imports the built-in `run` too. The
separate `async` pragma enables async syntax, signatures and the driver.
The syntax and classes are experimental.

## Shared execution machinery

Tasks and generators use the same private execution record, currently
named `PERL_GENERATOR`. Its stacks, activation pads, dynamic bindings and
cleanup machinery provide the ownership boundaries we need. Task creation
wraps a body in a private `XPerl::_Fiber`, rather than introducing another
stack representation.

The task object is separate. It holds results, dependencies and scheduling
state. The default driver is implemented in Perl behind a built-in entry
point. Stack preservation and exceptional resumption do not depend on that
driver.

| Private operation | Behavior |
| --- | --- |
| Create | Retain the body and capture its initial interpreter settings |
| Step | Start execution or resume with values |
| Exceptional step | Raise an exception at the suspended operation |
| Close | Reinstate bindings and unwind a suspended execution |
| Step result | Distinguish ordinary yield, dependency wait and completion |

Execution uses normal Perl frames and actual lexical storage. Arguments
retain their aliases. Signature parameters bind when the body starts.
Sharing a compiled sub does not share its live activation pad between
tasks. Closures and shared `state` variables retain normal Perl semantics.

Regex matches need an additional ownership boundary. The compiled regexp
holds captures and the matched subject, so saving `PL_curpm` alone lets a
second task overwrite the first task's `$1`. At a switch we move live match
results out of the shared regexp and retain its opcode binding. Resumption
puts the results back into the original regexp. This preserves ordinary
same-pattern behavior while an execution runs and avoids copying the subject.
Saved outer matches are included, even when an inner scope hides them.

A fresh task or generator starts without a previous match. Its captures
are undefined, and `//` cannot reuse its caller's pattern. This intentional
isolation avoids retaining an opcode owned by a caller that may have returned
before the new execution resumes. Completed core-engine matches with owned
subjects are supported across a park. Extension engines, borrowed subjects
and value-magic annotations are not supported there. The synchronous caller
guard preserves match metadata without claiming ownership of borrowed
subject bytes. Custom engines keep their ordinary nested-callback semantics
during cleanup.
Regex value-magic annotations are not isolated by this prototype.
Named capture values are isolated, but the iteration cursor of `each %+`
or `each %-` is shared. Collect the keys before awaiting if an iteration
must span suspension.

## Where suspension is safe

A private task dispatcher handles a suspending `OP_AWAIT` directly, passing
the actual execution owner. A nested native callback enters another
dispatcher and reaches the generic await entry. That entry may return an
available result, but cannot park an unfinished wait. Checking Perl stack
identity alone would not establish this boundary.

This preserves ordinary nested Perl calls without pretending that their
native callers can be retained. Sort, regex, tied and XS callbacks remain
suspension barriers. The ordinary dispatcher and ordinary generator
dispatcher do not gain an await check.

Every real park runs the localization preflight before detaching bindings.
The driver registers a waiter only after receiving a successful wait
packet. A caught preflight failure leaves no stale dependency or duplicate
wakeup. Available results require no park.

## Generators inside tasks

`XPerl::Task::next_value($generator)` drives a generator which may await.
The child returns to this ordinary Perl adapter with a distinct wait
result. The adapter awaits in its parent execution, then supplies the
value or exception to the child. It continues until an ordinary yield or
completion. Each native resume call returns before the outer execution
parks.

A token claims the generator throughout one adapter call. It owns a
reference to the wrapper. The execution borrows the token, and token
cleanup clears that pointer. There is no reference cycle. Exceptions and
cancellation release the claim. A replacement adapter first waits for any
dependency left by an abandoned adapter.

Raw generator calls and `iter` do not relay waits automatically.
Transparent iteration needs a resumable Perl wrapper or an interpreter
continuation for the original call. That is separate from proving the
stack machinery.

## Default driver policy

The driver manages a ready queue, dependencies and timers. A task created
inside a run joins its queue. An outside task stays unstarted until passed
to `run` or awaited. Running one outside task leaves unrelated tasks alone.

When the root finishes, unfinished work belonging to its run is cancelled
and unwound. Cleanup-created tasks stay unstarted for a later run.
Completed tasks leave the driver's strong registry immediately, so a long
root does not retain every child's result. Waiter references are weak.
Dependency cycles raise an exception instead of leaving an idle driver.

Cancellation closes an unstarted or suspended execution. It is terminal,
including when cleanup reports an error. Raising a dependency failure at
await is different: user code may catch it and continue. The default
cancellation exception has a distinct type. A running task cannot close
itself. Cleanup follows generator warning rules. An escaping exception does
not stop other tasks from unwinding. A root or driver failure takes
precedence over cleanup failures.

New interpreters start with an empty driver. Tasks and fibers skip cloning
because saved executions belong to their original interpreter. Async
factories retain their bodies with the existing refcounted XSUB payload,
which the interpreter knows how to clone.

## Review findings incorporated

Astra reviewed the native suspension boundaries, execution ownership and
cleanup paths. The review caught ways to orphan work during teardown,
retain completed results, lose an exception during driver loading, and
confuse two consumers of one generator. Independent probes confirmed the
capture fix, including hidden outer matches and abandonment inside regex
callbacks. The runtime retains canonical exception objects across awaits,
so catching a failure does not depend on reconstructing it from text.

## Current limits

There is no asynchronous I/O adapter yet. Timers require Time::HiRes and use
a monotonic clock when available. The fallback clock is wall time. The
default driver cannot be nested in the same interpreter.

`eval BLOCK` can span a wait. An unfinished await in `eval STRING` fails
the localization guard because its compiler saves are not isolated.
Other unsupported active localizations have the existing generator limits.

`__SUB__` refers to the raw body and bypasses task creation. Recursive async
code must use its declared name. Traditional named prototypes and
signatured anonymous async subs are supported. Async methods, lexical async
declarations and transparent generator iteration are not implemented.

The multisub follow-up adds `async multi sub`. Calls create tasks, and
dispatch runs inside those tasks. Every clause must be async. Guards can
await before selecting a clause, and a no-match failure reports the original
call file, line and lexical diagnostic language. The saved call metadata
does not retain the creator's code or package.

The library avoids cycles in its own waiter and relay machinery. It does
not collect arbitrary cycles created by application closures and task
references. Explicit cancellation can break execution ownership.

Scheduler-aware I/O and a stable public fiber interface should follow
after reviewing these semantics with working consumers.

## Next consumers

The next useful consumer is an I/O-backed task. Readiness callbacks can
complete that task and wake its waiters. The driver would wait for I/O when
its ready queue is empty, as it currently waits for timers. An ordinary
Perl helper could await that task without an async declaration.

Define the producer interface before making task fields or private fiber
methods public. Other libraries can provide their own `run` policy over
the same execution operations. The built-in driver can keep its own policy
without a configurable dispatcher or per-opcode scheduling checks.

## Validation and measurements

Validation completed on 2026-11-27:

| Build | Coverage | Result |
| --- | --- | --- |
| Threaded, ordinary stack, GCC 13.3.0, `-O3` | Full test suite | Pass |
| Threaded, reference-counted stack, debugging, `-O3 -g` | Generator and async tests, deparser, xperl pragma, stack cloning | Pass |
| Unthreaded, ordinary stack, debugging, ASan, `-O1 -g` | Generator and async tests, deparser, xperl pragma | Pass |

The sanitizer run used `PERL_DESTRUCT_LEVEL=2` and
`ASAN_OPTIONS=detect_leaks=1:abort_on_error=1` in an untraced tmux process.
It reported no address or leak errors. The compiler logs contained no
warnings. Astra independently checked hidden caller captures, native regex
cleanup and interpreter threads.

The benchmark compares the preserved interpreter from `689a901f46` with
`c63b0c2f5b`, on the same x86-64 Linux host with GCC 13.3.0, threads and
`-O3`. Runs were pinned to CPU 0 after validation builds finished, with
`PERL_HASH_SEED=0`, `PERL_PERTURB_KEYS=0` and `PERL_JSON_PP_USE_B=0`.
Each case had a warmup followed by repeated process-CPU measurements.
The table shows the median nanoseconds per loop iteration, not the cost
of an individual opcode. Ratios are after divided by before; larger means
more CPU time. CPU-tick resolution and code layout can affect small changes.

| Operation | Before (ns) | After (ns) | After / before |
| --- | ---: | ---: | ---: |
| Arithmetic loop | 45 | 45 | 1.000 |
| Ordinary sub call in a loop | 68 | 66 | 0.971 |
| Create and destroy a closure | 300 | 300 | 1.000 |
| Create and destroy an unstarted generator | 760 | 800 | 1.053 |
| Create, yield twice, destroy | 2,000 | 2,200 | 1.100 |
| Same operation retaining a capture | 2,600 | 3,600 | 1.385 |
| Create and destroy an unstarted task | — | 1,600 | — |
| Create and run an immediate task | — | 7,000 | — |
| Pending await and child task completion | — | 8,500 | — |
| Same await through ordinary helpers, depth 8 | — | 10,000 | — |
| Same await through ordinary helpers, depth 32 | — | 14,000 | — |

Ordinary execution showed no slowdown in these cases. Preserving matches
costs more at execution switches, particularly when a live capture needs
its result retained. The deeper-await cases include helper entry and exit,
child creation, driver work and completion, rather than measuring only the
stack exchange. These are relative measurements from one machine.
The immediate-task case starts a driver each iteration. The pending-await
cases use one driver for the whole sample and report CPU time per child
awaited. Subtracting those rows does not give the cost of suspension.

The script and raw samples are
[`async-await-bench.pl`](async-await-bench.pl) and
[`async-await-results.json`](async-await-results.json). The preserved
baseline executable used its original `feature.pm` because feature-bit
assignments differ between revisions. A separate baseline build can use
its own library directory instead.
