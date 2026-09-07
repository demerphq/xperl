# Fast `${^RNG}` providers

**Status:** Method-based XS callback discovery is implemented for the bundled
`RNG::PCG` provider. Fast seed callbacks, ABI versioning, and broader
hardening remain future work. The public byte-generation API is implemented
through the ordinary `rand_bytes` provider method; it is not a separate fast
callback ABI.

## Goal

`${^RNG}` keeps its existing Perl-level protocol:

```perl
local ${^RNG} = $object;       # calls $object->rand_bytes($length)
local ${^RNG} = sub { ... };   # calls the code reference with $length
```

For an XS provider, dispatching through Perl on every `rand()` call is
unnecessary overhead. The provider can expose an optional XS callback address.
Perl discovers that callback when `${^RNG}` changes and caches it for the
selected provider. The hot `rand()` path then calls the C function directly.
Providers may also expose a fixed-width 64-bit callback so `rand()` can avoid
the byte-buffer conversion entirely.

The provider object remains the source of RNG state. The cached callback is
only the execution mechanism used to obtain a native 64-bit word from that
state.

## Discovery protocol

When `${^RNG}` is assigned a blessed object, its magic performs this setup:

1. Ask the object whether its class can provide
   `get_rand_u64_XS_func_addr`.
2. Verify that the returned method CV is an XSUB. A Perl subroutine with this
   name is not allowed to provide an address and causes the normal fallback.
3. If the method is unavailable or is not an XSUB, clear the cached callback.
4. Call that exact XSUB CV on the selected object.
5. Treat `undef` or zero as “no fast callback”.
6. Treat a non-zero integer as a callback address.
7. Reject all other return values with an exception.

The method is deliberately called only when the selected `${^RNG}` value
changes or is restored by localization. It is not called by `rand()`.

The method is an XS-facing convention, not a replacement for `rand_bytes`.
The discovery method itself must be an XSUB. An XS implementation returns the
address using Perl's established pointer address convention, for example:

```c
RETVAL = PTR2UV(my_rand_u64_callback);
```

The integer-address convention is a trusted XS ABI. Core can validate the
shape of the returned Perl value and perform the platform's pointer
conversion, but it cannot prove that an arbitrary non-zero address returned by
trusted XS code points to a callable function with the correct signature.

The callback is discovered through an XSUB named
`get_rand_u64_XS_func_addr` and has this ABI:

```c
typedef U64 (*Perl_rng_u64_func)(pTHX_ SV *provider);
```

It returns the next 64-bit random word directly. `rand()` prefers this
callback and otherwise uses the Perl-level `rand_bytes` protocol.

## Current implementation

The implementation is split between `gv.c`, `mg.c`, and `pp.c`:

- `gv_magicalize()` installs ordinary special-variable magic when the main
  `${^RNG}` GV is created;
- the standard magic setter calls `rng_refresh()` for assignments and for
  save-stack localization/restoration;
- `S_rng_refresh()` validates the assigned provider and checks for the fast
  getter method, invokes an eligible XSUB, validates its result, and stores
  the callback in `PL_rng_u64`;
- `S_rng_provider()` performs only the initial refresh when the RNG GV is
  first fetched;
- `S_rng_u64()` uses the Perl-level `rand_bytes` protocol;
- The private `S_call_rand()` helper chooses the direct word path when the
  cached callback is set; `pp_rand` uses that helper directly so the hot path
  can be inlined, while the public `Perl_call_rand()` API remains available to
  other core and XS callers;
- `Perl_call_srand()` and `pp_srand()` continue using the existing Perl-level
  seed protocol.

The bundled `RNG::PCG` XS implementation exposes
`get_rand_u64_XS_func_addr()` and returns the address of its native-word
callback. Its ordinary `rand_bytes` method remains available for direct calls
and fallback use.

## Multiple providers and localization

Each provider object retains its own state. The cached callback is only for
the object currently stored in `${^RNG}`:

```text
${^RNG} = $rng1  -> cache rng1's callback, or NULL
${^RNG} = $rng2  -> replace it with rng2's callback, or NULL
local ${^RNG} = $rng3
                -> use rng3's callback, or NULL
scope exit      -> normal magical restoration selects the previous callback
```

The cache does not own or copy RNG state. `local ${^RNG}` changes which
provider is selected; it does not rewind or clone that provider's algorithm
state.

The normal save stack remains responsible for localization. The standard RNG
magic setter derives the cached callback from the visible value after both
assignment and restoration. It does not maintain a second restoration stack
or compare the current provider on every `rand()` call.

## Fast-path execution

The intended hot path is:

```c
SV *provider = S_rng_provider(aTHX_);

if (PL_rng_u64) {
    value = PL_rng_u64(aTHX_ PL_rng_sv);
}
else {
    value = S_rng_u64_via_perl(aTHX_ provider);
}
```

The fast path performs no `can`, method lookup, method dispatch, provider
validation, callback discovery, or registration work. Those costs occur only
when `${^RNG}` changes. The cached provider and callback are installed
together, so the hot path does not need a defensive provider lookup. The word
path avoids byte ordering and conversion;
the Perl-level path retains the existing canonical byte-string protocol.

## Ownership and safety

The callback address is process-level code; the provider argument is the
current interpreter-owned object containing mutable RNG state. The callback
must remain valid for as long as an object can select it. Unloadable XS
modules and callback replacement need an explicit lifetime policy before this
becomes a general public ABI.

If discovery raises an exception, the assignment must not leave a callable
stale pointer selected for the new value. Invalid values are rejected before
they are cached. Unblessed values and code references never use the XS
callback convention and continue through the existing Perl-level behavior.

## Future work

- Add an optional fast seed callback if `srand()` needs the same optimization.
- Decide whether the callback address ABI needs an explicit version marker.
- Define behavior for unloadable XS modules and callback lifetime.
- Test threaded cloning, interpreter destruction, and module unloading.
- Consider a public `rand_bytes()` core operation using the same buffer ABI.
- Benchmark eager callback discovery against any future lazy alternative.
- Decide whether class inheritance and overridden discovery methods need
  additional rules.

## Tests

The focused `dist/RNG/t/pcg.t` coverage includes:

- direct XS callback use without Perl `rand_bytes` dispatch;
- fallback for an object without the discovery method;
- invalid callback-address rejection;
- nested provider selection and restoration;
- deterministic agreement between direct provider calls and core `rand()`;
- string and numeric seeding behavior.

The relevant core validation also includes `t/op/srand.t`, diagnostic tests,
API regeneration checks, and porting tests.

## Prior art: magic-backed secondary state

The design follows existing Perl behavior where a visible Perl value controls
derived interpreter state. Examples include `%ENV`, signal variables, `@ISA`,
`%^H`, and debugger state. Their common pattern is:

```text
Perl assignment or localization
        |
        v
magic set/clear hook
        |
        +--> validate or interpret the new SV value
        +--> update secondary state or invalidate a cache
        +--> let normal save-stack restoration reverse the visible change
```

`${^RNG}` uses the same pattern: the visible provider value is authoritative,
and `PL_rng_u64` is derived cache state.

## Non-goals

This work does not change `${^RNG}` localization semantics, copy or rewind
RNG state, make Perl-level providers slower, or make `rand()` cryptographically
secure. It also does not require every RNG provider to implement XS.
