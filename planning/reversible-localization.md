# Reversible localization across execution contexts

Status: an experimental implementation for ordinary non-magical package
scalars, on `xperl/proto-localize`. Its original base was `25a9a387ee`.
It adds no public generator, async, or fiber API. The scalar design below
is the original implementation. Whole array/hash bindings, package loop
bindings and signal-entry
locals now extend it as described in the current support report.

Unsupported active localizations now prevent yield. See the
[yield check report](generator-yield-localization.md) for the current
policy and diagnostic. The scalar implementation history below describes
the earlier, narrower checks.

The prototype also preserves a defined set of interpreter settings based
on Coro's environment. See the [current support report](generator-coro-environment.md)
for those settings and their limits. This does not make other special
variables or aggregate localizations generally reversible.

## The problem and the design

Before this prototype, a generator executing `local $x = 'A'` left its
caller looking at that localized scalar after a yield. Another generator
or caller could replace it. Resuming the first generator then read or wrote
the wrong scalar. Switching save-stack pointers does not change what the
glob holds.

The implementation follows Yves's ordered unlocalize/relocalize design:

1. Record the localizations owned by this execution context.
2. On suspension, deactivate them in reverse order, preserving their SVs.
3. On resumption, reinstall them in forward order.
4. On actual scope exit, release them through ordinary scope unwind.

```perl
use generator;
our $x = 'original';
my $a = gen { local $x = 'A'; yield \$x; return $x };
my $b = gen { local $x = 'B'; yield \$x; return $x };
my $a_ref = $a->();
my $b_ref = $b->();
# $x is 'original'; $a_ref and $b_ref refer to different localized SVs.
my $a_value = $a->(); # A; $x is original again.
my $b_value = $b->(); # B; $x is original again.
```

These are binding exchanges, not value copies. Held references continue to
identify the same scalar. Neither deactivation nor reactivation leaves a
scope or runs its cleanup handlers.

## Existing scalar ownership

`save_scalar_flags` saves `[GV*, saved SV*, SAVEt_SV]`. The saved SV has two
references: the displaced glob-slot reference and an extra unwind guard.
The installed SV has one slot reference. An exchange preserves that balance:

```c
SV *live = GvSV(gv);
SV *saved = args[1].any_sv;
SvREFCNT_inc_simple_void(live);
GvSV(gv) = saved;
args[1].any_sv = live;
SvREFCNT_dec(saved);
```

The decrement cannot free a saved non-null SV because it retains the slot
reference. A null binding owns no references. This makes the exchange
callback-free, including when restoring a caller's tied or absent scalar.

The prototype converts validated scalar saves to `SAVEt_REVSV`, with the
same argument layout. Real scope exit restores the saved binding and
releases the outgoing local. It accepts a null saved binding and does not
call `mg_set` on the restored caller scalar. The plain local never used that
scalar's magic or changed its backing state, so restoring it must not
invent a tie `STORE`. The GV release has a save-stack guard in case outgoing
cleanup throws. Ordinary synchronous `local` keeps `SAVEt_SV` unchanged.

## Tracking and switching

The owner's private save stack already records its live localizations.
Its starting boundary is the bottom of that stack. Locals in ordinary
nested calls belong to the same owner; caller locals outside the execution
context do not. The boundary stays fixed across yields. It is not the
position of the previous yield or the lexical extent of the `gen` block.
Suspension walks it backwards without executing its restore operations.
The generated argument-count table supplies each record's width. `ALLOC`
and `REGCONTEXT` have additional variable-size payloads encoded in their
tags; other high tag bits are not lengths.

The context retains word offsets for eligible saves. It does not retain
pointers into save-stack storage, which can move while executing. Each
successful suspension rebuilds the active list because scopes may have
exited or new locals may have been introduced.

An ordered list alone suffices for the exchanges. Additional validation
checks nested locals and glob aliases. A scratch C hash table maps current
scalar-slot addresses to their first list entry. A single traversal assigns
alias groups and remembers each group's oldest entry. Resume rebuilds the
index from current GVs and checks the owner's saved state for conflicting
saves. Package foreach bindings join the replay list in their unwind order.
Merging or splitting ordinary slots
does not itself prevent replay.

The first prototype repeatedly searched the other entries for these answers,
which made its validation quadratic. The current implementation uses expected
linear work in live save records, scalar localizations, and loop contexts.
That qualification reflects hash-table lookup behavior. The binding replay
itself is linear. Arrays are retained for reuse and grow only when needed.
The scratch index is rebuilt before use; old GP addresses are not treated as
stable identities across suspension.

Ordinary variable access, ordinary local entry, and ordinary subroutine
entry/exit gain no checks. Costs occur at suspension, resumption, and cleanup.
The shared activation-pad machinery has its own separate boundary costs.

## Inheritance and lifecycle

For unlocalized ordinary package scalars, a resumed owner inherits the
resumer's current outside bindings. It does not capture the environment
from creation or first execution. Its own locals
are reinstalled above that environment. Variables it never localized follow
the current resumer naturally. This works when the resumer is another
suspendable owner, including when a child outlives its original caller.

All validation and allocation finish before any binding exchange. Pad
cleanup which can call Perl finishes before localization deactivation;
active pads and the exception guard remain installed during validation.
A failed yield leaves the bindings installed for ordinary exception unwind.
An unsupported overlap is rejected while the owner remains parked and can
be retried after removing that overlap.

Resume arguments have a save-stack guard. Validation runs before changing
argument ownership, then runs again after releasing old arguments because
their destructors can change aliases. Reentrant resumes during preparation
are rejected. Rejected arguments are released without retaining them on the
parked owner.

Return and uncaught exceptions use real scope unwind. Abandonment reinstalls
the owner's bindings before unwinding. Lexical destructors inside the local
scope therefore see the owner's local. The binding exchanges run no
destructors or tie methods.

Explicit close or exceptional resumption would need this same reactivation
before running or unwinding the private scopes. That integration is not
implemented here. The independent eval/try and lifecycle fixes are described
in [the execution-boundary report](execution-context-hardening.md).

Scalar replay follows each GV's current slot, just as ordinary restoration
does. A merged slot exposes the inner local through both names. A split
installs each local scalar into its current slot. Neither operation needs
to reconstruct the old alias layout. An ordinary name may alias the topic:
the owner's default bindings are installed before its scalar locals, and
removed after them. Aliases to error variables, overlaps with independent
owner-side topic or glob saves, and an owner merge which relocates an opaque
saved caller binding remain outside this plain-scalar prototype.
Destruction cannot request a retry. Its fallback marks all still-parked
`REVSV` saves for discard: real unwind releases their two private
SV references and GV guards without writing the new host slots. Owner-local
visibility during cleanup is unsupported on this fallback. User cleanup code
can itself access or modify currently visible globals. This is a limitation,
not a complete solution for those unsupported overlaps. Ordinary alias
merges and splits reactivate and unwind without this fallback.

Global interpreter destruction retains the existing stack-purge policy. It
does not reactivate every parked dynamic environment for language-level
cleanup. The prototype frees its index storage without installing bindings
in that path.

## Save-stack classification

Names omit `SAVEt_`. This inventory covers the baseline save types; `REVSV`
is the added scalar-binding record.

| Class | Save types |
| --- | --- |
| Reversible ordinary scalar bindings | SV, converted to REVSV after validation |
| Other bindings, containers, items and elements requiring separate protocols | AV, HV, GP, GVSV, GVSLOT, ITEM, AELEM, HELEM, DELETE, ADELETE |
| Pointer restores whose target lifetime or ownership needs examination | GENERIC_PVREF, GENERIC_SVREF, SHARED_PVREF, SVREF, RCPV, APTR, HPTR, PPTR, SPTR, VPTR |
| Numeric and flag restores on potentially shared addresses | BOOL, I8, I16, I32, I32_SMALL, INT, INT_SMALL, IV, STRLEN, STRLEN_SMALL, SET_SVFLAGS, READONLY_OFF |
| Interpreter, compiler, pad and stack bookkeeping | CLEARPADRANGE, CLEARSV, COMPPAD, COMPILE_WARNINGS, CURCOP_WARNINGS, HINTS, HINTS_HH, OP, PADSV, PADSV_NULL, PADSV_AND_MORTALIZE, PARSER, SAVESWITCHSTACK, STACK_POS, TMPSFLOOR |
| Cleanup operations, never executed merely to switch contexts | DESTRUCTOR, DESTRUCTOR_X, FREECOPHH, FREEOP, FREEPADNAME, FREEPV, FREERCPV, FREESV, FREE_REXC_STATE, MORTALIZESV, NSTAB |
| Variable-size opaque payloads to skip correctly | ALLOC, REGCONTEXT |

The current op, active compilation pad, stack positions, and temporary floor
already travel in the execution record. Pad cleanup acts on the owner's
activation storage. Other bookkeeping tags need individual examination:
compiler hints and arbitrary pointer restores are not automatically isolated
just because their save entries belong to the private stack. Native parser
or XS activations cannot be preserved by exchanging Perl save stacks.

## Supported cases and limits

The implementation supports named, initially non-magical scalar bindings,
nested locals, changing glob aliases, scalar references, and values containing
references to objects. After suspension the caller may modify, tie, or remove
its scalar slot with `undef *name`. Its actual binding is restored without
copying it or invoking its magic.

Active magical locals are rejected. Some internal magic might be harmless,
but this prototype makes no such classification. Direct localizations of
the default topic and error variables retain their existing handling rather
than joining this scalar protocol. An ordinary name sharing the topic's GP
can participate if its scalar is plain and no independent owner-side topic
save overlaps it. Arrays, hashes and elements retain their
existing behavior. Unsupported interactions within a tracked scalar group,
including independent scalar-slot alias saves, are rejected
before exchanging any bindings. This is not a blanket isolation guarantee
for every unsupported localization elsewhere in the context.

The provisional rejection uses the existing continuation-unavailable
structured diagnostic. A production interface needs a diagnostic explaining
the unsupported localization rather than a generic continuation error.
`ss_dup` recognizes the new record and its nullable two-reference saved SV.
Ordinary thread creation tests do not exercise `CLONEf_COPY_STACKS`; direct
embedding clones with that flag need separate validation.

## Validation and measurements

`op/generator_local.t` checks binding identity, nested locals, current-resumer
inheritance, tied and absent caller slots, ordinary alias merges/splits,
reentrant preparation, cleanup visibility, weak resources, and thread
snapshots. Its index stress case grows from one binding to many distinct
slots mixed with repeated locals and aliases, shrinks, then regrows through
an overlapping set. `op/generator_local_random.t` checks reproducible arbitrary
interleavings, caller writes, completion, exceptions, and abandonment.

The optimized regular build passes these tests. Debugging regular-stack and
threaded reference-counted-stack builds pass with ASan/LSan,
`PERL_DESTRUCT_LEVEL=2`, and leak detection enabled outside a traced process.

`Porting/bench-generator-local` records raw samples and actual save-stack
word counts before each yield loop. The comparison uses baseline `25a9a387ee`
and this prototype on one x86-64 Linux host, unthreaded `-O3` builds,
10,000 switch pairs per sample, nine measured samples after a warm-up, and
`CLOCK_MONOTONIC`. Each switch pair resumes and yields again. Ordinary read
and local controls use larger loops. Raw samples accompany this report.

| Workload | Save words | Baseline ns | Prototype ns |
| --- | ---: | ---: | ---: |
| Ordinary scalar read | - | 23 | 17 |
| Ordinary scalar local | - | 44 | 45 |
| No package locals | 2 | 288 | 321 |
| 1 local | 5 | 311 | 335 |
| 8 locals, distinct scalars | 26 | 301 | 555 |
| 32 locals, distinct scalars | 98 | 273 | 1276 |
| 64 locals, distinct scalars | 194 | 310 | 2090 |
| 128 locals, distinct scalars | 386 | 272 | 3918 |
| 256 locals, distinct scalars | 770 | 273 | 8432 |
| 8 locals, one scalar | 26 | 263 | 539 |
| 32 locals, one scalar | 98 | 276 | 1227 |
| No package locals, 8 lexical scopes | 10 | 300 | 340 |
| No package locals, 32 lexical scopes | 34 | 327 | 519 |
| No package locals, 64 lexical scopes | 66 | 434 | 699 |
| 8 locals, distinct scalars, 32 lexical scopes | 58 | 337 | 918 |

The distinct-local measurements grow approximately in proportion to the
number of bindings. The original quadratic validation measured about
5,049 ns at 64 distinct locals on this host; the indexed version measures
about 2,090 ns. Unchanged-path variation, particularly the early read
control, shows why these should be treated as relative measurements rather
than evidence of an ordinary-execution speedup.

The current-glob replay update was measured separately on 2026-11-25 with
the same optimized regular configuration, iteration count and sampling
method. It includes the intervening lifecycle fixes. Raw samples are in
[reversible-localization-current-globs.json](reversible-localization-current-globs.json).

| Current replay workload | ns per switch pair |
| --- | ---: |
| No package locals | 276 |
| 8 distinct locals | 571 |
| 32 distinct locals | 1399 |
| 64 distinct locals | 2512 |
| 128 distinct locals | 5391 |
| 256 distinct locals | 10053 |
| 8 distinct locals and 32 lexical scopes | 1240 |

Validation now rechecks the parked owner's save records and loop contexts
against the current aliases. Argument destruction can change those aliases,
so the check is repeated before installing incoming arguments. The work
remains expected-linear. A future optimization could record which scopes
need conflict checks at suspension, avoiding a full rescan when no such
records exist. These measurements do not isolate that cost from the
intervening lifecycle changes.

The topic-alias update was measured on 2026-11-25 using the same optimized
regular build, 10,000 switch pairs per sample and nine measured samples.
The before column is the current-glob run above. The after samples are in
[reversible-localization-topic-aliases.json](reversible-localization-topic-aliases.json).

| Workload | Before ns | After ns |
| --- | ---: | ---: |
| Ordinary scalar read | 19.4 | 18.2 |
| Ordinary scalar localization | 43.3 | 41.6 |
| Switch pair, no package locals | 276 | 287 |
| Switch pair, 8 distinct locals | 571 | 559 |
| Switch pair, 32 distinct locals | 1399 | 1421 |
| Switch pair, 64 distinct locals | 2512 | 2493 |
| Switch pair, 128 distinct locals | 5391 | 4609 |
| Switch pair, 256 distinct locals | 10053 | 10394 |
| Switch pair, 8 locals and 32 lexical scopes | 1240 | 1248 |

These are medians on one machine, not evidence of an ordinary-execution
speedup. The unchanged controls vary too. The implementation adds no work
to ordinary variable access, localization, subroutine entry or opcode
dispatch. The extra conflict checks run in the existing context-switch
scans, whose cost continues to grow with the owner's saved state.

The scratch table adds memory in exchange for avoiding repeated searches.
It uses a power-of-two bucket array at most half full, plus ordered records
and cached oldest-entry indices. Capacity is reused across yields. There is
no copy of localized values and no additional reference to an old caller's
binding after successful deactivation.

To reproduce from a configured checkout:

```sh
make
./perl -Ilib t/op/generator_local.t
./perl -Ilib t/op/generator_local_random.t
./perl -Ilib Porting/bench-generator-local --iterations 10000 --samples 9
```

## Roadmap

- Classify harmless internal scalar magic before extending its support.
  Yield now reports unsupported active localizations explicitly.
- Plain whole package arrays and hashes now use reversible bindings.
  Their saves own one aggregate reference, unlike the scalar save's two.
  Internal iterator and weak-reference bookkeeping stays with the object.
  Ties, inheritance arrays, symbol tables and other externally meaningful
  magic need their own handling.
- Ordinary aggregate element locals cannot cross yield. Supporting them
  needs a separate semantic decision and must account for deletion,
  resizing and existing references to elements.
- Add reversible handling for owner-side glob saves in their real save-stack
  order. Ordinary scalar restoration follows current globs and needs no
  frozen alias graph. Independent topic saves, error slots and opaque saved
  bindings need their own handling before removing the remaining discard
  fallback.
- Extend the signal-entry protocol only after resolving its unsupported
  forms, including direct `delete local`, whole hashes and ties. Other
  special interpreter variables and `%ENV` need their own protocols.
  Do not run tie or signal hooks halfway through a switch.
- Extend the pointer/numeric allowlist only after auditing each target.
  Their tag alone does not establish private storage or its lifetime.

Reversible localization does not capture a parent dynamic environment.
A future execution abstraction wanting that inheritance must choose an
additional policy. Native callback suspension and the remaining exception
lifecycle issues described in the suspension audit are separate work.
