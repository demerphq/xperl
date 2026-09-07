# RNG provider benchmark report

Date: 2026-09-07

## Scope

This compares the core `rand()` path using the built-in generator and the
bundled providers. Provider cases install an object in `${^RNG}` and exercise
the same cached U64 callback path used by normal callers.

The Perl executable was the current local xperl production build, configured
with `-O3`, without `DEBUGGING`, and without threads. Fast-provider results
use ten million `rand()` calls. HMAC_DRBG and SHA use one million calls
because they are substantially slower. Each result is the mean of three
`perf stat` runs measuring `cycles` and `instructions`.

## Core `rand()` results

| Provider | Calls | Cycles | Instructions | Cycles/call | Relative cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| built-in | 10,000,000 | 722,497,060 | 3,065,511,422 | 72.2 | 1.000x |
| RNG::PCG | 10,000,000 | 1,075,015,690 | 2,946,403,901 | 107.5 | 1.488x |
| RNG::Wyrand | 10,000,000 | 1,068,132,447 | 2,876,542,169 | 106.8 | 1.478x |
| RNG::Xoshiro | 10,000,000 | 1,016,685,325 | 2,786,295,390 | 101.7 | 1.407x |

The three XS providers are within about fifty percent of the built-in path in
this production build, with Xoshiro the fastest of the three in this run. The
remaining cost is not Perl method dispatch: the callback is called directly
from the core. It is primarily the cost of the algorithm, plus common `rand`
opcode and numeric conversion work.

## Slow/reference providers

| Provider | Calls | Cycles | Instructions | Cycles/call | Relative to built-in |
| --- | ---: | ---: | ---: | ---: | ---: |
| RNG::HMAC_DRBG | 1,000,000 | 15,369,067,931 | 56,902,807,144 | 15,369.1 | 212.7x |
| RNG::SHA | 1,000,000 | 3,339,176,537 | 9,850,618,607 | 3,339.2 | 46.2x |

HMAC_DRBG is substantially slower than the small non-cryptographic generators
because each request performs HMAC-SHA-256 state evolution. The pure-Perl
SHA implementation remains an illustrative provider rather than a competitive
implementation. The use of SHA-256 does not by itself make that construction
a reviewed cryptographic DRBG.

## Profile summary

Profiles used `perf record -F 997 -g`. Fast providers used ten million calls;
HMAC_DRBG and SHA used one million. Samples were not lost. The profiles were
collected from the same production build as the timing table.

| Provider | Profile observations |
| --- | --- |
| built-in | Shared `pp_rand`, iteration, numeric conversion, and result handling dominate. |
| RNG::PCG | Shared `rand` work remains dominant; `pcg_rng_u64_fast` is visible in the callback path. |
| RNG::Wyrand | Shared `rand` work remains dominant; the mixing function is largely optimized into the callback. |
| RNG::Xoshiro | Shared `rand` work remains dominant; `xoshiro_u64_fast` is visible in the callback path. |
| RNG::HMAC_DRBG | `hmac_sha256_transform` accounts for about 81% of samples. |
| RNG::SHA | Cost is spread across `shafinish`, `sha256`, and Perl scalar/hash/magic operations. |

The profile confirms that callback lookup is not occurring in the hot path.
The provider callback and algorithm body account for the expected additional
work, while the rest is shared Perl execution and conversion overhead.

## Interpretation

The fast-provider design is meeting its main goal: an XS provider can be
selected dynamically without paying for Perl method dispatch on every random
value. The provider interface adds a measurable but modest cost relative to
the built-in path, while algorithm and result-conversion costs dominate.

These results do not establish that one generator is statistically or
cryptographically superior to another. They measure one call shape on one
optimized, non-threaded build and should be repeated on the target platform
and with the intended workload before making provider choices on performance
grounds.
