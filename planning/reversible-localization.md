# Reversible localization across execution contexts

Status: an experimental implementation for ordinary non-magical package
scalars, on `prototype/reversible-localization`, based on `25a9a387ee`.
It adds no public generator, async, or fiber API. The other localization
classes discussed below are not implemented.

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
index from the current GVs and detects groups that have merged or split.
Conflicting saves and package foreach aliases use the same index.

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
An incompatible resumer is rejected while the owner remains parked and can
be retried after restoring compatible aliases.

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
implemented here. Existing eval/try continuation defects are separate;
binding exchanges do not repair exception resumption across a yield.

If tracked slots merge or split, or a tracked glob is retargeted to a
special GV, ordinary resume rejects that environment. An ordinary GP
replacement which preserves the group relationships is accepted.
Destruction cannot request a retry. Its fallback marks all still-parked
`REVSV` saves for discard: real unwind releases their two private
SV references and GV guards without writing the new host slots. Owner-local
visibility during cleanup is unsupported on this fallback. User cleanup code
can itself access or modify currently visible globals. This is a limitation,
not a complete solution for arbitrary glob rebinding.

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
nested locals, stable glob aliases, scalar references, and values containing
references to objects. After suspension the caller may modify, tie, or remove
its scalar slot with `undef *name`. Its actual binding is restored without
copying it or invoking its magic.

Active magical locals are rejected. Some internal magic might be harmless,
but this prototype makes no such classification. Special GVs, including the
default topic and error variables, retain their existing handling rather
than joining this scalar protocol. Arrays, hashes and elements retain their
existing behavior. Unsupported interactions within a tracked scalar group,
including scalar-slot alias saves and package foreach aliases, are rejected
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
inheritance, tied and absent caller slots, alias merges/splits and retry,
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

- Classify harmless internal scalar magic and add a precise unsupported-case
  diagnostic before enabling this generally.
- Extend container binding exchange to plain package AVs/HVs only after
  establishing their reference and magic rules.
- Treat elements by container identity and logical index/key. An AV resize
  or deleted hash entry invalidates a cached slot pointer. Preserve absence
  separately from an existing undefined value, and plan any allocation before
  exchanging bindings.
- Model GP/glob operations as a complete binding graph. Decide cleanup
  semantics after structural edits instead of extending the discard fallback
  into a claim of full support.
- Give special interpreter variables, ties, `%ENV`, and `%SIG` their own
  protocols. External state and arbitrary callbacks require failure and
  rollback policies beyond pointer exchange. Do not run tie or signal hooks
  halfway through a switch.
- Audit arbitrary pointer/numeric saves individually. Their tag alone does
  not identify private versus shared storage or prove its lifetime.

Reversible localization does not capture a parent dynamic environment.
A future execution abstraction wanting that inheritance must choose an
additional policy. Native callback suspension and the remaining exception
lifecycle issues described in the suspension audit are separate work.
