# XPerl differences from mainline Perl

XPerl adds experimental language features, a different hash implementation,
and bundled tools for everyday programming. This document introduces the
main differences between `xperl/main` and mainline Perl (`blead`).
The linked manuals explain the individual APIs and their limits.

For the exact source changes, use:

```text
git diff perl5/blead...HEAD
```

## AI contributions

XPerl permits AI-assisted contributions. The mainline `AI-POLICY` document
has been removed.

## Language features

### Enabling XPerl

`use xperl` enables the current XPerl language and its supporting functions.
It turns on strictness and warnings, silences experimental warnings, and
imports builtins and standard pattern predicates into the current lexical
scope. Older syntax such as `switch` and indirect method calls stays disabled.

The pragma follows the interpreter's current feature set. Programs that need
a fixed selection can continue to import individual features and functions.
See [xperl](lib/xperl.pm).

### Generators

A generator is a function that can pause and later continue where it left
off. A `gen` block creates one. `yield` hands values back to its caller.
Calling it again resumes the suspended code. The `generator` pragma enables
this feature, as does `use xperl`.

```perl
use xperl;

my $letters = gen {
    for my $letter ("A".."E") {
        yield $letter;
    }
    return;
};

my $numbers = gen {
    for my $number (1..5) {
        yield $number;
    }
    return;
};

for (iter($letters)) {
    print $_, scalar($numbers->()), " ";
}
say "done" if $letters->exhausted;

# A1 B2 C3 D4 E5 done
```

Generators are cooperative: the caller chooses when to resume them. They
create no threads or scheduler. Calls can send values back into a suspended
`yield`, and programs can inspect whether a generator is running, completed,
failed, or exhausted.

Each generator keeps its lexical variables, `$_`, `@_`, and error bindings
across suspension. Supported package-variable localizations, including
ordinary scalars, whole arrays and hashes, and individual signal handlers,
are put aside on yield and reinstated on resume. The caller sees its own
bindings while the generator is suspended. Generators preserve selected
interpreter settings too, including the input record separator.

A generator cannot yield with unsupported localizations still in scope,
such as ordinary array or hash elements, whole globs, or tied variables.
These may be used in scopes which end before yielding. Suspension checks
report an exception before putting any bindings aside.

See [perlgenerator](pod/perlgenerator.pod) for calling rules, cleanup,
and suspension limits.

### Iterators

The `iterator` package gives ordinary callable code the same completion
protocol as generators. Completion is explicit, so an empty result need not
mean that the sequence has ended. Implementations can also expose whether
they support restarting.

`iter($iterator)` lets `for`, `map`, and `grep` pull one item at a time when
it is their sole input. It does not build the entire input before the body
starts, and `last` stops pulling. `iter($callable, $stop)` also accepts a
closure or callable object, stopping before the sentinel value. `map` and
`grep` still collect their results in the usual way.

See [perliterator](pod/perliterator.pod), [iterator](lib/iterator.pm), and
[iter](lib/builtin.pm#iter).

### Classes and roles

Roles let classes share fields, methods, field initializers, and `ADJUST`
blocks. A role can also require methods from its consumers. Classes and
other roles consume them with the experimental `:implements` attribute.

```perl
use feature 'class';

role Named {
    method name() { "a named object" }
}

class Person :implements(Named) {
    field $name :param;
    method name() { $name }
}
```

A role included through several paths is composed once. Conflicting fields
or methods are reported during composition. Programs can test declared role
membership, including roles inherited from a superclass; `DOES` recognizes
these roles too.

Native classes can define custom constructors. Every class has a `CONSTRUCT`
method that allocates an object, initializes its fields, and runs `ADJUST`.
By default, `new` is an alias for it. A custom `new` can prepare arguments
first:

```perl
use v5.36;
use feature 'class';

class Point {
    field $x :param :reader;
    field $y :param :reader;

    sub new ($class, $x, $y = 0) {
        return $class->CONSTRUCT(x => $x, y => $y);
    }
}

my $point = Point->new(10, 20);
```

Each native subclass gets its own default `new`. A subclass that wants a
parent's custom constructor must forward to it explicitly.

Classes can also work with conventional blessed objects. Calling `CONSTRUCT`
on an existing object adds class fields without changing its identity,
blessing, or ordinary contents. This lets a conventional parent constructor
create the object first. Subclasses can explicitly share inherited fields;
private fields remain private.

Serialization helpers expose class fields to tools such as `Data::Dumper`.
`TEARDOWN` runs before fields are released during destruction or reblessing.
If `DESTROY` resurrects the object, its fields remain live.

See [perlclass](pod/perlclass.pod) for roles, constructors, field ownership,
serialization, and lifecycle rules.

### Structured exceptions

Errors and warnings carry information that programs can inspect: a diagnostic
identifier, arguments, source locations, and context. Default rendering keeps
familiar Perl messages. Applications can also request annotated text, JSON,
or Dumper output.

A structured exception hook runs before the existing warning and die hooks.
A two-variable `catch` can retain both the compatibility value and the
structured exception. After `eval`, `${^ERROR_OBJ}` provides the exception
object even when `$@` preserves an application's thrown reference.

See [the exception guide](pod/perlexcept.pod),
[XPerl::Exception](lib/XPerl/Exception.pm), and
[XPerl::Diagnostic](lib/XPerl/Diagnostic.pm).

### Translated diagnostics

Loadable language packs translate catalogued errors and warnings, with
English as the fallback. Programs can choose a language for a lexical scope
or at runtime. Application text passed to `die` or `warn` is not translated
automatically.

Alongside English, translations are available in Arabic, Chinese
(Simplified), Dutch, Finnish, French, German, Hebrew, Hungarian, Icelandic,
Italian, Persian, Polish, Portuguese, Russian, Serbian, Spanish, Turkish,
Ukrainian, and Welsh. Klingon is included separately as a constructed-language
test case. The translations are machine drafts awaiting native-speaker review.

Diagnostic rendering handles language-specific plural forms. The
`cardinal_plural_form` and `ordinal_plural_form` builtins make those rules
available to programs too.

See [diagpack](lib/diagpack.pm) for language selection and pack loading.

### Dispatch/on matching

The experimental `dispatch_on` feature selects code according to a value's
shape. A `dispatch` evaluates its subject once and tries ordered `on`
clauses. The first match runs. `on (_)` provides a default clause. If no
clause matches, `dispatch` throws a structured no-match exception, reported
at the dispatch statement.

Patterns can describe literals, arrays, hashes, nested structures, class
objects, regular expressions, and numeric or reference criteria. Scalar
names capture values for use within a clause, while `^` pins an existing
value. An optional `if` guard runs after the shape matches.

Class patterns accept subclasses and inspect fields without constructing
objects or calling field accessors. Matching can still run application code
through predicates, ties, overloads, or an overridden `isa` method.
This feature is independent of `given`/`when`.

See [the tutorial](pod/perldispatchontut.pod) and
[the reference](pod/perldispatchon.pod).

### Multi subroutines and methods

The experimental `multisub` feature lets a subroutine or method have several
clauses selected by argument patterns. Perl tries clauses in source order
and runs the first whose pattern and optional guard succeed:

```perl
use feature 'multisub';
no warnings 'experimental::multisub';

multi sub magnitude($value if $value < 0) { -$value }
multi sub magnitude($value)               { $value }

print magnitude(-42), "\n"; # 42
```

These declarations use the dispatch/on pattern language. Their parameters
are patterns rather than signatures: scalar captures receive copies, while
`@_` retains the original argument aliases. Clause bodies share the public
subroutine's identity and calling context. A multi method matches explicit
arguments after its normal method setup.

A call with no matching clause throws an exception at the call site. Clauses
for one name must be declared in the same lexical scope and
compilation unit. Ordinary and multi declarations cannot share a name.

See [perlmultitut](pod/perlmultitut.pod), [perlsub](pod/perlsub.pod#multisubs),
and [perlclass](pod/perlclass.pod#multi-method).

### Builtins and one-liners

The `-E` switch enables `feature ':all'` and imports `builtin ':all'`, making
XPerl's experimental keywords and builtins available in one-liners. Their
normal experimental warnings apply. The behavior of `-e` is unchanged.

New builtins include SipHash hashing, jump consistent hashing, diagnostic
catalog lookup, plural-form selection, role tests, and class serialization.
SipHash accepts byte strings and optional keys. Jump consistent hash assigns
integer or string keys to numbered buckets while minimizing reassignment
when the bucket count grows. Its mapping does not depend on Perl's hash seed.

See [builtin](lib/builtin.pm) and [perlrun](pod/perlrun.pod).

## Hash storage and iteration

### Insertion order

Ordinary, unrestricted hashes preserve insertion order. `keys`, `values`,
and `each` traverse entries in the order their keys were first inserted.
Updating a value keeps its position. Deleting a key and inserting it again
moves it to the end. Growth and compaction preserve the order of surviving
entries.
Key-restricted hashes can keep a deleted key's old position. Tied hashes
control their own iteration order.

Hash-function seeding remains enabled, but it does not control iteration
order. Bucket-order perturbation, `PERL_PERTURB_KEYS`, and
`Hash::Util::hash_traversal_mask` are removed. Inserting a new key while
`each` is in progress invalidates its iterator.

### Compact storage

Ordinary hashes keep their entries in a compact array. Small hashes avoid
the overhead of a separate lookup index. Larger hashes add one. The default
uses compact integer chains, with open addressing available as a build option.
Both implementations preserve the same Perl-facing ordering and operations.

The shared-key table, which lets hashes reuse key strings, has a separate
implementation. Shared key addresses remain stable while referenced, even
when that table grows. Thread cloning gives each interpreter its own table.

`Hash::Util` provides storage inspection, capacity reservation, and shared-key
inspection tools. The changes can reduce memory use and improve traversal,
but performance depends on the workload. Some smaller indexed hashes remain
slower than `blead` for insertion and repeated deletion/reinsertion.

See [the design and benchmark report](Porting/hash-oa-design.pod) for storage
options, capacity limits, measurements, and pointer-lifetime rules.

## Bundled distributions and tools

### Added CPAN distributions

These distributions are bundled in addition to those supplied by `blead`,
with their supporting modules, documentation, and tests.

| Distribution | Purpose |
| --- | --- |
| `Cpanel::JSON::XS` | JSON encoding and decoding |
| `DBI` | Database interface |
| `DBD::SQLite` | SQLite database driver |
| `IO::Socket::SSL` | TLS sockets |
| `Net::SSLeay` | OpenSSL/LibreSSL bindings |
| `Perl::Tidy` | Perl source formatting |
| `TOML::Tiny` | TOML parsing and writing |
| `Text::CSV_XS` | CSV parsing and writing |
| `YAML::XS` | YAML parsing and writing |

### RNG

The experimental [RNG](dist/RNG/lib/RNG.pm) distribution provides selectable
random-number generators and reusable random distributions. `${^RNG}` selects
the provider used by `rand`, `srand`, and `builtin::rand_bytes`. Localizing it
selects a different provider for that scope. Each provider owns its state.
Changing the selection does not copy or rewind it.

Bundled providers include Drand48, HMAC_DRBG, PCG, Wyrand, and Xoshiro.
These providers expose `state` and `set_state` for snapshots and restoration.
Bundled XS providers use a native path for `rand`. This bypasses subclass
`rand_bytes` overrides. Pure-Perl providers use the byte protocol instead.
See [perlrng](pod/perlrng.pod).

### Tensor-XS

The experimental `Tensor-XS` distribution provides `Tensor::XS` and the Perl
`Tensor`, `Matrix`, `Vector`, and `Scalar` classes backed by contiguous XS
storage. It supports integer and floating-point data, indexed access, bulk
operations, and native access bridges. `MNIST` supplies helpers for reading
the MNIST dataset format.

The numerical API and binary representation are experimental. See
[Changes](dist/Tensor-XS/Changes) and [the XS design](dist/Tensor-XS/XS_DESIGN.md).

### XStats, XBench, and XGraph

These distributions provide statistics, benchmarking, and graph tools:

| Distribution | Purpose |
| --- | --- |
| [XStats](dist/XStats/lib/XStats.pm) | Statistics with retained observations or bounded summaries, plus resampling and probability functions |
| [XBench](dist/XBench/lib/XBench.pm) | Calibrated benchmarks with retained samples and confidence intervals |
| [XGraph](dist/XGraph/lib/XGraph.pm) | Compact directed graphs and graph algorithms, with DOT import/export |

The statistics objects are `XStats::Full` and `XStats::Sparse`, constructed
with `Full` or `Sparse`. `XStats::Functions` provides standalone functions.

### Core support modules

The language features add the `xperl`, `generator`, and `iterator` modules,
along with standard pattern predicates in `dispatch::Predicates`.
`XPerl::Exception`, `XPerl::Diagnostic`, and related modules provide diagnostic
inspection, module-owned diagnostic catalogs, and language-pack loading.

Their references are linked from the language sections above. Each shipped
diagnostic language pack has its own loadable extension.

### Interactive shell and utilities

`xperl-repl` starts an interactive Perl shell. It keeps lexical variables,
the current package, and compile-time hints between inputs. It recognizes
incomplete input, so expressions can span several lines.

On Unix-like terminals, `Term::ReadLine::XPerl` provides history, completion,
key bindings, and UTF-8 editing without an external library. Other systems
use the `Term::ReadLine` stub. See [XPerl::REPL](lib/XPerl/REPL.pm).

The utility list also adds `xbench`, `perltidy`, and `perltidy-auto`.
The JSON distribution supplies `cpanel_json_xs`.

### Changes to existing modules

`Data::Dumper` preserves native class fields, shared references, and ordinary
object contents. It adds opt-in `Useutf8` and `PreserveUnicode` settings for
Unicode output and round trips. `Storable` requires explicit freeze/thaw
hooks for native class objects so hidden fields cannot be silently discarded.

The bundled `Perl::Tidy` fork understands multi declarations, including
patterns, guards, and repeated subroutine or method clauses. Exception-related
modules and tools adapt to structured diagnostics, while introspection and
source tools account for the new language operations.

`utf8::repeat_decode` removes repeated UTF-8 encoding from input known to have
that problem. It modifies the input in place and can force a final UTF-8
representation. It does not guess the intended encoding of arbitrary text.
See [utf8](lib/utf8.pm).

## Compatibility and builds

The language features and runtime interfaces are experimental and may change.
Existing Perl behavior is preserved where practical, including when features
are disabled. C and XS extensions can identify XPerl with `#ifdef XPERL`.

The hash representation changes the XS ABI: extensions must be rebuilt.
Code that accesses hash internals also needs adaptation. Hash entry pointers
can become invalid when storage moves or compacts, and the shared-key table
can no longer be treated as an ordinary Perl hash. See
[perlguts](pod/perlguts.pod) and [the hash design report](Porting/hash-oa-design.pod).

Parser, opcode, diagnostic, and documentation changes include their generated
files and platform build integration. Regenerate those outputs when changing
their source definitions.
