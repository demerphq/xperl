# Shared activation pads and suspended Perl stacks

The fix gives each suspended execution exclusive ownership of its live
activation pads. It does not copy lexical values or clone the executing
CVs. Bookkeeping runs at execution boundaries rather than on ordinary
subroutine entry, exit, or opcode dispatch.

## The bug

Two generators made by the same factory can share the compiled generator
body. They must nevertheless keep separate arguments and lexical
variables. Before this fix, finishing one generator could let a new call
reuse another suspended generator's storage:

```perl
use generator;

sub factory {
    gen {
        my $value = $_[0];
        yield $value;
        return $value;
    };
}

my ($a, $b, $c, $d) = map { factory() } 1 .. 4;
print $a->('A'), "\n";
print $b->('B'), "\n";
print $a->(), "\n";
print $c->('C'), "\n";
print $d->('D'), "\n";
print $b->(), "\n"; # Must be B; the affected runtime returns D.
```

This reproduces on the generator runtime at `f97d2b8bd4`. The same problem
applies to ordinary named subs called on private execution stacks.
Destroying an older generator or unwinding it after an exception can cause
the same corruption.

Perl normally associates a CV's activation pads with its recursion depth.
Returning from a call restores the depth saved on entry. That assumes
nested call lifetimes. A suspended call can outlive a call which entered
before it, so restoring that earlier depth can expose storage which is
still in use. Saving `CvDEPTH` alone cannot prevent another call from
reusing that storage.

## Ownership rules

On first suspension, we inspect the private Perl context stack and find
each CV's live activations. We move their actual pad AVs into a private
padlist owned by the execution record. The CV receives spare pads made
using the existing recursion-allocation rules. Outer captures, constants,
and `state` bindings retain the sharing those rules require.

The following invariants apply:

- A parked activation's live pad AV belongs to its execution record. It is
  absent from the padlist available to outside calls.
- Each lexical SV, argument alias, and escaped reference keeps its identity.
  Moving the pad AV does not replace or copy its contents.
- A CV has the running execution's padlist and depth installed. Normal Perl
  calls and returns use those values without additional checks.
- Resume saves the currently installed outside padlist and depth before
  installing the private pair. Suspension restores that saved pair. We do
  not assume that the resumer is the original caller.
- Callers below the execution boundary retain their own padlist and live
  frames. Only activations on the private stack move into private storage.
- Completed CV activations release their private padlists at the next
  boundary. Failure and abandonment reinstall private pads before unwinding.

Private padlists retain their CV and pad names. Escaped lexical subs with
weak outside links receive a strong outside link before their private pad
is released, so later CV destruction cannot leave them pointing at freed
code. Their statically captured lexical SVs already have their own normal
references. The private stack's initial compilation pad is null rather
than a borrowed pointer into its first caller's activation.

A CV-local list records parked owners. It prevents `undef &name` from
freeing code with suspended activations. Interpreter cloning starts with
an empty owner list because generator continuations are not cloned.
Relinking an owner's record in this list takes constant time.

## String eval

A closure which explicitly mentions an outer lexical already captures its
SV. A closure which mentions that lexical only inside string `eval` can
instead look through `CvOUTSIDE` at eval time. Detaching a pad must not
make that existing lookup find an empty spare frame.

A running activation retains the usual precedence. If no activation of
the outside CV is running, lookup uses its most recently parked live
activation. Parking again updates that order. This retains the dynamic
nature of string-eval lookup rather than turning it into a new static
capture. Different outside CVs have independent lists.

When the last activation retires, ordinary inactive-pad lookup applies.
Fresh spare lexical slots are marked stale so an unavailable lexical
produces the usual warning. The lookup does not keep a generator or its
resources alive. A child interpreter receives no parent suspension state;
static captures follow ordinary thread-cloning rules.

## Validation

`op/generator_pad.t` covers shared body CVs, shared ordinary helpers,
recursion, outside callers, current-resumer restoration, argument aliases,
lexical references, captured state, lexical subs, string eval, exceptions,
abandonment, thread cloning, and explicit reference cycles.

`op/generator_pad_random.t` exercises reproducible interleavings at varied
call depths. It checks frame values and arguments, weak resource references,
and exact destruction after arbitrary completion, failure, or abandonment.
It verifies that retiring one context leaves the resources of its parked
siblings alive. `XS-APItest` checks warmed SV counts after escaped closures
outlive their owners and are then released.

The focused generator, iterator, closure, recursion, state, and XS tests
pass on the optimized regular build. Ownership and resource tests pass
with debugging and AddressSanitizer on both regular stacks and threaded
reference-counted stacks. Leak runs use `PERL_DESTRUCT_LEVEL=2` and
`detect_leaks=1` outside a traced process. Shutdown probes include live
global generators and a retained reference cycle. Warmed SV counts show no
growth after escaped closures and their owners are released.

## Performance

`Porting/bench-generator-pads` measures ordinary arithmetic and subroutine
calls, generator creation, first suspension, resumption, destruction, and
switching through recursive call stacks. Run it with the built interpreter:

```sh
./perl -Ilib Porting/bench-generator-pads --iterations 10000 --samples 7
```

Measurements below are from one x86-64 Linux host on 24 November 2026.
Both interpreters use the same unthreaded `-O3` configuration. The baseline
is the saved `f97d2b8bd4` interpreter. The comparison uses this patch,
10,000 iterations, and medians of nine samples after a warm-up sample.
Units are nanoseconds per operation. Depth labels count additional
recursive helper levels, beyond the owner, helper, and yielding leaf.

| Operation | Before | After |
| --- | ---: | ---: |
| Arithmetic loop iteration | 22.6 | 17.0 |
| Ordinary subroutine call | 65.0 | 67.2 |
| Explicit-return subroutine call | 64.8 | 66.0 |
| Create generator | 197.7 | 198.6 |
| Start and suspend | 670.2 | 622.6 |
| Resume and suspend among parked peers | 631.4 | 541.8 |
| Destroy unstarted generator | 307.5 | 273.9 |
| Destroy suspended generator | 1164.0 | 1227.8 |
| Resume at depth 0 | 198.8 | 241.1 |
| Resume at depth 1 | 203.2 | 263.1 |
| Resume at depth 4 | 205.4 | 263.4 |
| Resume at depth 16 | 220.6 | 309.4 |
| Resume at depth 64 | 291.5 | 466.1 |

Creation, destruction and ordinary-execution timings vary between runs,
including paths whose implementation is unchanged. These are relative
measurements on one machine, not evidence that ordinary execution becomes
faster.

The source adds no ordinary subroutine-entry, subroutine-exit, or
opcode-dispatch checks.
The extra helper call in `pad_push` is confined to allocating a missing
recursion frame. String-eval lookup and explicit CV undefinition perform
the additional CV-owner lookup.

Each yield inspects live frames and allocates replacement frames and
private padlist metadata for newly encountered CVs. Resumption installs
the saved private padlists without another live-frame scan.
A stack with many distinct CVs requires more record lookups than recursion
through the same CV. The implementation uses a linear owner-record search
for each live Perl frame, so the worst-case boundary scan is quadratic in
the number of distinct CVs on that stack. There is no corresponding scan
on ordinary synchronous calls.

## Remaining limits

This fixes activation-pad ownership. Dynamic package localizations still
need separate switching support: swapping save-stack pointers alone does
not deactivate a paused `local`. Native C frames are not preserved by the
Perl stack snapshot. Existing exception-resumption and cleanup issues are
separate changes, described in [the suspension audit](execution-suspension.md).

The patch adds no public generator operations or other execution APIs.
