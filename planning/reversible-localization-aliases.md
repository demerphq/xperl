# Scalar localization follows the current glob

This assessment describes the scalar prototype on `xperl/proto-localize`.
Code and test references refer to that branch.

Perl restores a localized package scalar through the glob's current scalar
slot. It does not promise to preserve the alias relationships that existed
when the scope began.

```perl
$A = "bar";
$B = "baz";
{
    local $A = "foo";
    *A = *B;
}
print "$A / $B";  # bar / bar
```

The glob assignment makes A and B share a GP and its scalar slot. Leaving
the scope installs A's saved scalar through that shared slot. A reference
taken to B's previous scalar still refers to that old scalar. References
to the globs themselves do not show the change: A and B remain distinct
GV objects even while sharing a GP.

With `local *A = *B`, the glob save unwinds before the scalar save. That
restores A's old GP first, so the final values are `bar / baz`.

Our earlier assessment assumed that a suspended owner must retain its
original alias groups. That was stronger than ordinary Perl semantics.
It led to unnecessary resume rejection and an incorrect discard fallback
for ordinary merges and splits. Pinning old GPs or introducing new scalar
slot representations is not required for these cases.

## Suspension and replay

Suspension exchanges owned scalar bindings in reverse save order.
Resumption exchanges them in forward order. Each operation resolves its
saved GV's current scalar slot.

If the caller merges A and B while the owner is parked, replaying an
outer `local $A` and an inner `local $B` makes the inner binding visible
through both names. Leaving the inner scope exposes the outer binding
through both names. Both scalar objects retain their identity, including
through escaped references. The current caller binding is restored when
the owner parks or finishes.

If the caller splits a previously shared slot, replay installs each
local scalar in its current slot. Each caller slot gets its own outside
scalar back. Caller writes between activations remain intact.

If the owner itself changes aliases while running, deactivation follows
those changed globs, just as ordinary scope exit would. This can change
which outside scalar a name exposes. The example above deliberately
restores A's original scalar into B's slot.

The exchanges operate only on scalar slots. They do not reinstall an old
GP or replace unlocalized array, hash, code or IO slots. Whole-glob changes
made explicitly by Perl code have their ordinary effects on those slots.

## Validation uses the owner's saved state

The slot index describes the current globs. It detects overlapping saves
which the scalar prototype cannot replay, rather than requiring the old
and current alias groups to match.

A changed alias can introduce overlap with an owner's saved glob or
package foreach binding. Resume checks the parked owner's save and
context stacks. A foreach in the resumer is a different scope and must not
be mistaken for an owner conflict. Checks run again after old argument
cleanup because its destructors can change globs.

The index keeps this work expected-linear. Revalidation scans save records
and loop contexts at execution boundaries. Ordinary scalar access and
ordinary subroutine calls gain no checks.

## Aliases to the topic

An ordinary name can share the topic's GP, including after the owner has
parked. Install the owner's default bindings before replaying its scalar
locals. An ordinary local can then override the owner's topic through the
shared slot. Suspension removes the locals first and swaps the caller's
defaults back afterwards. These operations must be exact inverses.

Real scope exit, failure and abandonment run with the owner's defaults and
locals installed. Cleanup therefore sees the private scalar, while the
caller gets its own topic and argument array back by identity. A caller
write to the topic between activations survives.

This supports ordinary topic aliases, not every operation which binds the
topic. A direct owner-side `local $_`, package foreach, `given`, or unnamed
`dispatch` has its own restoration order. If it overlaps scalar replay,
the prototype rejects the overlap before changing bindings. Removing the
alias allows the owner to resume. A resumer's topic scope is outside the
owner and is not such a conflict.

## Remaining prototype limits

Ordinary merges and splits now replay and unwind normally, including
abandonment. Three distinct cases remain outside this change:

* An overlapping owner-side `local *glob` has its own GP restoration.
  It needs reversible handling in the right order with scalar saves.
  A resumer's `local *glob` may establish the current alias relationships
  normally.
* Aliases to `$@` and `${^ERROR_OBJ}` remain excluded. So do overlaps with
  an owner's independent topic saves, as described above. Supporting these
  needs ordered replay of the additional saves, not just scalar locals.
* An owner-side merge can move a displaced magical or absent caller
  binding into a record now considered an inner localization. The current
  plain-binding checks conservatively reject that combination. Supporting
  it needs provenance for outside bindings, without admitting magical
  localizations created by the owner.

For unsupported overlaps and special slots, the discard fallback can
still release references without reconstructing the owner's full
environment for destructors. That remaining limitation must not be
described as a reason to reject ordinary alias changes.

The regression cases are in
[generator_local.t](https://github.com/demerphq/xperl/blob/xperl/proto-localize/t/op/generator_local.t). They check values,
scalar identities, nested scope order, outside writes, active-owner
aliasing, destruction and exceptions. The planning probes illustrate
ordinary alias layout and cleanup visibility:

```sh
./perl -Ilib planning/probes/localization-slot-topology.pl
./perl -Ilib planning/probes/localization-cleanup-observations.pl
```
