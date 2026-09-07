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
| built-in | 10,000,000 | 804,019,846 | 3,345,567,192 | 80.4 | 1.000x |
| RNG::PCG | 10,000,000 | 1,057,311,272 | 3,092,266,892 | 105.7 | 1.315x |
| RNG::Wyrand | 10,000,000 | 1,048,888,382 | 3,022,238,990 | 104.9 | 1.304x |
| RNG::Xoshiro | 10,000,000 | 1,016,472,564 | 2,932,034,477 | 101.6 | 1.264x |

The three XS providers are within about one-third of the built-in path in
this production build, with Xoshiro the fastest of the three in this run. The
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
`dumbbench`.  This run covers the built-in provider and the three fast XS
providers; the slower SHA and HMAC_DRBG providers were intentionally omitted.

| Provider | Time per iteration | Relative to built-in |
| --- | ---: | ---: |
| built-in | 19.57 ms | 1.00x |
| RNG::PCG | 27.91 ms | 1.43x |
| RNG::Wyrand | 27.205 ms | 1.39x |
| RNG::Xoshiro | 26.60 ms | 1.36x |

These practical figures show the fixed startup and setup costs alongside a
substantial number of calls.  They are useful for short-lived programs, while
the production `perf` table above is the better comparison for long-running
code that has already selected its provider.
