# Replaying scalar locals during generator cleanup

This assessment concerns the scalar prototype at commit `46e254d668` on
`xperl/proto-localize`. It identifies a limitation to resolve before
promising safe cleanup after arbitrary glob-alias changes.

The ordered swap works whenever the caller still gives the localized
globs the same scalar-slot relationships. Keep that path. The caller may
have different scalar values, ties or an empty slot. Those are already
handled by exchanging the actual SV pointers.

The troublesome case is a change to which names share a slot. The
prototype detects it on explicit resume, but if the generator is destroyed
in that state its DESTROY methods run in the wrong scalar environment.
In the merge probe the destructor reads `host right / host right`; the
two live locals should read `owner left / owner right`. In the special
glob probe the destructor reads the caller's topic. The caller's values
survive, but that alone is insufficient for cleanup.

## Why saving the original glob does not settle it

In `gv.h:11`, a GP holds the scalar, array, hash, code, format and IO
slots together. `GvSV(gv)` is the actual `gp_sv` field. A full-glob
alias shares this *slot*. Assigning the same scalar reference to two
separate globs shares the *current SV*. A subsequent `local` replaces
the slot, which exposes the difference.

Suppose A and B shared a GP when the owner suspended. The caller splits
them and installs different arrays. During cleanup, a destructor performs
both of these ordinary operations:

* Reading `$A[0]` and `$B[0]` should see the two caller arrays. The
  generator never localized either array.
* Inside `{ local $A = 'nested'; ... }`, reading `$B` should see
  `nested` if the owner retains its original shared scalar slot.

`slot-topology.pl` demonstrates that one GP meets the second condition
but exposes the same array twice. Two GPs with the same scalar referent
meet the first condition but `$B` keeps the previous scalar. Installing
different GPs on entry and restoring them on exit cannot meet both
conditions throughout the callback using Perl's current representation.
The reverse case involves two private scalar locals that now need to
appear distinct while their caller shares the two complete globs.

Keeping the original GP alive also has an observable cost. With a caller
using `local *original`, a GP pin kept objects in both the caller's
scalar and array alive after its scope ended. Without the pin both
destructors ran on scope exit. A pin cannot freeze changes made through
another alias. It also does not change the GV used by an already compiled
variable access. In core, `gp_ref` clears a cached method CV, and
`gp_free` can release user objects or clear the effective GV. The
existing glob restore in `scope.c` deals with ISA and method caches.
Treating these operations as raw, callback-free pointer exchanges would
introduce separate lifetime and method-lookup changes.

## Identity and aliases outside the saved records

After deleting and recreating a stash entry, a compiled closure and a
symbolic lookup can correctly name different globs with the same spelling.
The teardown probe reads `owner / replacement`. Afterwards it reads
`original / replacement`. Keep save records keyed to the actual GV and
compare current slot addresses at each boundary. Recreating names from
package strings would rebind the replacement symbol by mistake.

An untracked alias created while the owner is parked can also legitimately
see the local. In the probe, `local *untracked = *left` makes cleanup
observe `private / private`, and both names read the host value afterwards.
A shadow GP installed only on the tracked GV loses this relationship.
The GP has one effective GV and a reference count. It has no list of
every alias, including globs reachable solely through saved references.

## Two ways forward

1. **Keep destructive topology changes out of a parked owner's lifetime.**
   With this policy, the current ordered swaps give cleanup the full owner
   environment. Reject incompatible full-glob reassignments before changing
   any slot. A guard must include the special GVs: rebinding a special GV
   to a tracked GP can create the conflict in the opposite direction. A
   singleton change to an unrelated ordinary GP can remain valid.

   An assignment guard alone is insufficient. A generator can first park
   inside a caller's `local *A` when A and B are independent. Leaving that
   already-open caller scope can merge A and B. The probe reproduces this
   with no explicit glob assignment after suspension. Scope exit must
   remain possible. A conservative first version could reject suspension
   before exchanging anything if an outstanding glob restore might create
   a conflict. It must account for pending restores in resumers as well
   as in the private stack. A registry updated on glob localization and
   restoration is one way to avoid searching across saved stacks. The
   policy needs an explicit contract for native code that changes GPs
   directly. These hooks belong on structural changes and at suspension;
   neither ordinary scalar reads nor ordinary scalar `local` needs a
   check. This approach changes which glob operations or suspensions are
   allowed, so it calls for a language policy decision first.

2. **Allow arbitrary topology changes and give each scalar alias group an
   independently rebindable slot.** This needs a representation that can
   share a scalar slot while the containing GPs differ, or an equivalent
   mechanism that intercepts every scalar-slot rebind during replay.
   Simply caching the same SV in several GPs fails at nested `local`.
   The lvalue form of `GvSV` is also used by native code. This route
   needs a separate design covering ordinary accesses, structural writes,
   references and extension compatibility. The two probes above rule out
   accomplishing it by rearranging current GPs only at the boundaries.

An intermediate policy could promise only the values of explicitly
localized scalars during incompatible teardown and use private globs for
those names. That gives up some behavior inside user destructors (nested
localization, untracked aliases or unlocalized glob slots). It would also
need to remove the overlay at each group's last actual scope exit so
later cleanup sees that caller's outside bindings. Do not ship such a
fallback as restoration of the full owner environment.

Run the accompanying probes with the prototype interpreter and its library
directory. The first demonstrates the GP representation without requiring
reversible localization. The second exercises the prototype's cleanup:

```sh
./perl -Ilib planning/probes/localization-slot-topology.pl
./perl -Ilib planning/probes/localization-cleanup-observations.pl
```
