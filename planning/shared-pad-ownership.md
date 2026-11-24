# Shared activation pads and suspended Perl stacks

Status: confirmed existing correctness bug, not yet fixed. Investigated on
24 November 2026 against the generator runtime based on `f97d2b8bd4`.

## Confirmed behavior

The runtime can suspend an entire private Perl call chain, including
ordinary nested subroutine frames. That does not make independently
scheduled call chains safe. Perl keeps `CvDEPTH` on the shared CV, outside
the swappable execution record. Normal subroutine exit restores the depth
saved when that activation was entered.

If context A and context B suspend in the same CV, B can own a deeper pad.
Returning from or closing A restores an earlier depth even though B still
owns its activation. A new invocation can consequently reuse B's pad and
overwrite its arguments and lexical variables.

The issue is reachable through existing public generators. It does not
require a proposed fiber API or an unsafe XS callback:

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

The CV template in this factory does not require ordinary closure cloning,
so the wrappers share it. The independent probe using two distinct leaf CVs
also reproduced corruption in a shared ordinary named helper. Finishing
the younger activation before the older one preserved the expected
values. A debug/reference-counted build can stop on a pad/depth invariant
instead of silently returning the wrong value.

`close` makes this existing ownership problem easier to exercise, but does
not introduce it. Ordinary out-of-order return is enough.

## Constraints on the fix

Each parked execution must retain exclusive ownership of its live
activation pads. Outside execution must not allocate those pads again.
Restoring only `PL_curpad`, or only `CvDEPTH`, is insufficient.

The fix must preserve ordinary closure bindings, shared state variables,
constants, lexical subs, argument aliases, recursive calls, and caller
frames which are live below a nested execution owner. Cloning every CV
without examining those semantics is not an established solution.

The suspension boundary provides a place to discover the actual live
`CXt_SUB` frames, their CVs, saved depths, and pad AVs. A candidate design
detaches those activation pads while the context is parked and reinstalls
them on resume. `pad_push` is the existing source of rules for constructing
recursion-equivalent pads while sharing outer/state bindings correctly.

The candidate must account for padlist identities, saved argument arrays,
saved compilation-pad pointers, and the outside depth/padlist displaced
during a resume. Directly predicting an `OP_ENTERSUB` target is fragile in
the presence of method dispatch, overload, AUTOLOAD, XS and tail calls.

This is a design direction, not a completed implementation. It should be
tested at context boundaries before considering changes to ordinary
opcode dispatch. There is no requirement for a scheduler or async-state
poll on every synchronous opcode.

## Required regression cases

- Out-of-order normal return, explicit close, failure, and abandonment.
- A third invocation while an older context remains suspended.
- Several wrappers from the same generator factory.
- Shared ordinary helpers and recursion at different depths.
- Captured lexicals and shared `state` variables.
- Arguments and references to arguments or lexical variables.
- A running caller invoking an execution context using that same CV.
- Regular and reference-counted stacks, debug assertions, and leak checks.

## Consequences for async and fibers

Whole-stack preservation is confirmed. Full independent activation
ownership is not. A general-purpose fiber scheduler must not be described
as safe until this bug is fixed.

Conventional async which restricts `await` to an async body still needs
independent pads for concurrent invocations of that body. Allowing `await`
from an ordinary nested Perl helper additionally requires protecting each
intervening activation. There is no demonstrated interpreter requirement
to declare every such helper async once that ownership problem is solved.

Native C activations remain a separate restriction. Preserving Perl frames
does not preserve a native callback which has not returned. A safe explicit
suspension operation parks only when control returns to its owning Perl
run loop. Scheduler-aware I/O can be built above that boundary using
nonblocking operations and readiness notifications; it cannot make an
arbitrary blocking XS routine suspend safely.
