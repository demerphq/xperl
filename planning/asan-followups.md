# ASan and inherited test follow-ups

This note records results from the ASan build used to validate the experimental
case/match feature.  It separates case/match results from failures in unrelated
bundled modules and inherited thread tests.

## Build and commands

The build was configured with threaded DEBUGGING and AddressSanitizer.  The
full harness was run with:

```sh
PERL_DESTRUCT_LEVEL=2 \
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
make -j8 test_harness TEST_JOBS=16
```

The case/match focused test passed independently:

```sh
PERL_DESTRUCT_LEVEL=2 \
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
./perl -Ilib t/comp/case_match.t
```

All 128 tests passed.  The focused five-file case/match harness should also be
run under this configuration before the ASan work is considered complete.

LeakSanitizer must remain disabled in the restricted agent environment.  A run
with `detect_leaks=1` aborts with:

```text
LeakSanitizer has encountered a fatal error.
LeakSanitizer does not work under ptrace
```

A valid LSan result requires a run outside that ptrace-restricted environment,
and must use `PERL_DESTRUCT_LEVEL=2`.

## TODO tests that passed

The full ASan run reported TODO passes for GH 16522, GH 16863, GH 16869, and
GH 16876.  These tests check that DEBUGGING assertion failures do not occur.
Git history shows the tests being added or their status being adjusted, but no
specific case/match or xperl commit that fixes the underlying issues.  The
current result therefore means that these old failures are not reproduced in
this build; it does not identify a new fix.  They should remain TODO until the
corresponding upstream tests are intentionally promoted.

`PERL_DESTRUCT_LEVEL=2` is not the reason these tests pass.  That setting
controls shutdown cleanup and leak visibility; these tests exercise assertions
in unrelated compiler, glob, and regexp paths.

## Cpanel::JSON::XS ASan failures

The full harness reported:

```text
cpan/Cpanel-JSON-XS/t/00_load.t       SIGABRT
cpan/Cpanel-JSON-XS/xt/gh70-asan.t    SIGABRT
```

Both reproduce with leak detection disabled.  ASan reports a heap-buffer
over-read in:

```text
cpan/Cpanel-JSON-XS/XS.xs:5064
XS_Cpanel__JSON__XS_new
```

The failing read is the GH70 short-class-name case.  The `xt/gh70-asan.t`
test intentionally exercises this over-read, so its abort is expected when the
test is run under ASan.  The ordinary `00_load.t` test reaches the same code
through the short subclass name `J` and exposes the same bundled-module bug.

This is unrelated to case/match.  Follow-up options are:

1. fix the Cpanel::JSON::XS constructor's bounded class-name comparison;
2. keep the intentional GH70 test out of a purportedly clean full ASan
   harness, while retaining it as a negative ASan regression test; and
3. rerun the module's ordinary tests after that fix.

Do not mark the full ASan harness clean while these tests are included.

## `threads/t/libc.t` failures

The full run reported ten failures in the thread-safe `localtime()` stress
test.  A direct run reproduces the issue both with and without
`PERL_DESTRUCT_LEVEL=2`; the failures are not leak-checking failures.  Typical
results are nonzero error counts such as 1 through 9 from the worker threads.

The test precomputes scalar `localtime()` results in the parent, then calls
`localtime()` 20,000 times in each of ten Perl threads and compares the result.
The normal threaded DEBUGGING `make_test` passed this test, while the ASan
build fails repeatedly.  This points to an ASan/thread scheduling or libc
interaction, but it has not yet been reduced to a minimal reproducer.

Follow-up work:

- compare the same test on a threaded non-ASan production build;
- run it repeatedly under ASan and capture complete worker results;
- inspect Perl's threaded `localtime()` implementation and the libc calls it
  selects;
- determine whether the failure is a pre-existing sanitizer-only race or a
  real thread-safety regression;
- if it is sanitizer-specific, document the limitation rather than weakening
  the test; otherwise fix the implementation and add a focused regression.

## Current conclusion

Case/match passes its direct ASan coverage.  A completely clean full ASan
run is currently blocked by the unrelated Cpanel::JSON::XS GH70 over-read and
the threaded `localtime()` stress failures.  Those must be tracked separately
from case/match ownership and cleanup validation.
