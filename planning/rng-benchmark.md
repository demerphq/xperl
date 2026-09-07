# RNG provider benchmark report

Date: 2026-09-07

## Scope

This compares the core `rand()` path using the built-in generator and the
bundled providers. Provider cases install an object in `${^RNG}` and exercise
the same cached U64 callback path used by normal callers.

The Perl executable was the current local xperl production build, configured
with `-O3`, without `DEBUGGING`, and without threads. Fast-provider results
use ten million `rand()` calls. HMAC_DRBG and SHA use one million calls
because they are substantially slower. Fast-provider results are the mean of
five `perf stat` runs; HMAC_DRBG and SHA results are the mean of three runs.
All runs measure `cycles` and `instructions`.

## Core `rand()` results

| Provider | Calls | Cycles | Instructions | Cycles/call | Relative cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| built-in | 10,000,000 | 801,841,196 | 3,343,642,864 | 80.2 | 1.000x |
| RNG::Drand48 | 10,000,000 | 922,271,617 | 2,772,913,205 | 92.2 | 1.150x |
| RNG::Xoshiro | 10,000,000 | 946,430,677 | 2,900,834,347 | 94.6 | 1.180x |
| RNG::Wyrand | 10,000,000 | 984,341,480 | 2,990,203,967 | 98.4 | 1.227x |
| RNG::PCG | 10,000,000 | 988,605,770 | 3,059,892,494 | 98.9 | 1.233x |

The four XS providers are within about one-quarter of the built-in path in
this production build, with Drand48 and Xoshiro the fastest of the four in
this run. The
remaining cost is not Perl method dispatch: the callback is called directly
from the inlined `rand` opcode path from the core. It is primarily the cost of
the algorithm, plus common `rand` opcode and numeric conversion work.

## Slow/reference providers

| Provider | Calls | Cycles | Instructions | Cycles/call | Relative to built-in |
| --- | ---: | ---: | ---: | ---: | ---: |
| RNG::HMAC_DRBG | 1,000,000 | 15,325,403,668 | 56,919,986,757 | 15,325.4 | 190.6x |
| RNG::SHA | 1,000,000 | 3,297,815,767 | 9,892,153,184 | 3,297.8 | 41.0x |

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
| RNG::Drand48 | Shared `rand` work remains dominant; the compatible LCG callback is visible in the callback path. |
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

## Practical `dumbbench` results

This second measurement uses the built xperl executable to perform 1,000,000
`rand()` calls per process.  It uses `dumbbench --no-dry-run`, because the
default dry-run subtraction is inappropriate for this short-process workload.
The result includes process startup, module loading, provider construction,
and the calls.  Values are the rounded time per iteration reported by
`dumbbench`.  This run covers the built-in provider and the four fast XS
providers; the slower SHA and HMAC_DRBG providers were intentionally omitted.

| Provider | Time per iteration | Relative to built-in |
| --- | ---: | ---: |
| built-in | 19.81 ms | 1.00x |
| RNG::Drand48 | 24.746 ms | 1.25x |
| RNG::Xoshiro | 24.67 ms | 1.25x |
| RNG::PCG | 25.744 ms | 1.30x |
| RNG::Wyrand | 26.26 ms | 1.33x |

These practical figures show the fixed startup and setup costs alongside a
substantial number of calls.  They are useful for short-lived programs, while
the production `perf` table above is the better comparison for long-running
code that has already selected its provider.
