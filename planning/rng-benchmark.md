# RNG provider benchmark report

Date: 2026-09-07

## Scope

This compares the core `rand()` path using the built-in generator and the
bundled XS providers.  The provider cases install an object in `${^RNG}` and
therefore exercise the same cached U64 callback path used by normal callers.

The SHA provider is measured separately because it is a pure-Perl proof of
concept and is not intended to be a serious performance target.

The Perl executable used for this run was the current local xperl build.  The
build included debugging support, so these numbers should be treated as a
relative comparison rather than production throughput figures.  Each result
uses ten million `rand()` calls and is the mean of three `perf stat` runs with
`cycles` and `instructions` selected.

## Core `rand()` results

| Provider | Calls | Cycles | Instructions | Elapsed seconds | Cycles/call | Relative cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| built-in | 10,000,000 | 5,384,635,681 | 16,626,693,480 | 1.17897 | 538.5 | 1.000x |
| RNG::PCG | 10,000,000 | 5,938,156,980 | 17,746,692,032 | 1.28568 | 593.8 | 1.103x |
| RNG::Wyrand | 10,000,000 | 5,984,423,698 | 17,537,023,049 | 1.31446 | 598.4 | 1.111x |
| RNG::Xoshiro | 10,000,000 | 5,910,219,102 | 17,586,683,327 | 1.31419 | 591.0 | 1.098x |

The three XS providers are within about eleven percent of the built-in path.
The remaining cost is not Perl method dispatch: the callback is called
directly from the core.  It is primarily the cost of running each algorithm,
plus the common `rand` opcode and numeric conversion work.

## SHA reference-provider result

`RNG::SHA` was measured with one million calls:

| Provider | Calls | Cycles | Instructions | Elapsed seconds | Approx. cycles/call |
| --- | ---: | ---: | ---: | ---: | ---: |
| RNG::SHA | 1,000,000 | 14,919,831,433 | 29,171,936,550 | 3.50209 | 14,919.8 |

At approximately 27.7 times the built-in cycles per call, this confirms that
the pure-Perl SHA implementation is an illustrative provider rather than a
competitive implementation.  The use of SHA-256 does not by itself make this
construction a reviewed cryptographic DRBG.  A future serious cryptographic
provider should use a reviewed construction, such as an AES-CTR or hash-based
DRBG specified by an applicable standard, with appropriate entropy and
reseed handling.

## Profile summary

The profile used twenty million calls per provider with `perf record -F 997
-g`.  Samples were not lost.

| Provider | `pp_rand` children | `call_rand` children | Provider callback | Generator body |
| --- | ---: | ---: | ---: | ---: |
| built-in | not comparable as a provider callback | not applicable | not applicable | default PRNG path |
| RNG::PCG | 33.37% | 17.70% | 9.63% | `pcg_next_u64` 5.43% |
| RNG::Wyrand | 32.03% | 16.88% | 9.04% | `wyrand_next` 4.89% |
| RNG::Xoshiro | 27.39% | 12.87% | 7.28% | `xoshiro_next` 4.02% |

The profile confirms that callback lookup is not occurring in the hot path.
The provider callback and algorithm body account for the expected additional
work, while the rest is shared Perl execution and conversion overhead.

## Interpretation

The fast-provider design is meeting its main goal: an XS provider can be
selected dynamically without paying for Perl method dispatch on every random
value.  The current algorithms are close enough to the built-in path that the
provider choice is dominated by algorithm quality and state requirements,
rather than by the provider interface.

The current results do not establish that one generator is statistically or
cryptographically superior to another.  They measure only this call shape on
this debug build and should be repeated on a non-debugging build before making
claims about production throughput.
