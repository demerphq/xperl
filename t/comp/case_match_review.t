#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc(qw(. ../lib));
}

# Cross-feature regressions from the implementation/documentation review.
# Test observable results AND process status: a crash after printing the
# expected result must not pass. These regressions were originally failing;
# keep their expectations independent of the implementation being tested.
sub check_case {
    my ($name, $code, $expected) = @_;
    my $result = fresh_perl(
        "use strict; use warnings; use feature qw(case_match say);\n" . $code,
        {},
    );
    my $status = $?;
    is($result, $expected, $name);
    is($status, 0, "$name: clean exit");
}

# Every backend must implement the same source-order and scalar-kind rules.
# Select the mode before the subprocess compiles its cases.
for my $mode (qw(none array-linear array-binary hv auto)) {
    local $ENV{PERL_CASE_DISPATCH} = $mode;
    check_case("$mode: literal kinds and defaults", q{
        for my $value (1, '1', 7, '7') {
            case ($value) {
                match ('1') { say 'string' }
                match (1)   { say 'number' }
                match (_)   { say 'default' }
            }
        }
    }, "number\nstring\ndefault\ndefault");

    check_case("$mode: numeric caching does not change a string's kind", q{
        my $value = '1';
        my $number = 0 + $value;
        case ($value) {
            match (1)   { say 'number' }
            match ('1') { say 'string' }
            match (_)   { say 'default' }
        }
    }, 'string');

    check_case("$mode: numeric lower/upper bounds and in-range misses", q{
        for my $value (1, 2, 3, 4, 5, 6, 7) {
            case ($value) {
                match (2) { say 'two' }
                match (4) { say 'four' }
                match (6) { say 'six' }
                match (_) { say 'miss' }
            }
        }
    }, "miss\ntwo\nmiss\nfour\nmiss\nsix\nmiss");

    check_case("$mode: signed bounds preserve unsigned hits", q{
        my $maximum = ~0;
        my $literal = sprintf '%u', $maximum;
        my $matcher = eval 'sub { my ($value) = @_; case ($value) {'
            . 'match (-1) { "negative" } match (' . $literal
            . ') { "unsigned" } match (_) { "miss" } } }';
        die $@ if $@;
        say $matcher->($_) for (-2, -1, 0, $maximum - 1, $maximum);
    }, "miss\nnegative\nmiss\nmiss\nunsigned");

    check_case("$mode: unsigned values exceed wholly negative bounds", q{
        case (~0) {
            match (-4) { say 'wrong' }
            match (-1) { say 'wrong' }
            match (_) { say 'miss' }
        }
    }, 'miss');

    check_case("$mode: byte and UTF-8 representations compare by characters", q{
        my $text = chr(233);
        for (1 .. 2) {
            case ($text) {
                match ("\x{e9}") { say 'hit' }
                match (_)        { say 'miss' }
            }
            utf8::upgrade($text);
        }
    }, "hit\nhit");

    check_case("$mode: byte mode compares raw encodings", q{
        my $text = chr(233);
        utf8::upgrade($text);
        my $encoded = $text;
        utf8::encode($encoded);
        use bytes;
        for my $value ($text, $encoded) {
            case ($value) {
                match ("\xc3\xa9") { say 'hit' }
                match (_) { say 'miss' }
            }
        }
    }, "hit\nhit");

    check_case("$mode: scalar/list/void contexts inside a subroutine", q{
        sub context_name {
            return !defined(wantarray) ? 'void'
                 : wantarray ? 'list' : 'scalar';
        }
        sub selected {
            case (1) { match (1) { context_name() } }
        }
        my $scalar = selected();
        my @list = selected();
        say "$scalar,@list";
        my $void;
        sub observe_void {
            $void = !defined(wantarray);
        }
        case (1) { match (1) { observe_void() } }
        say $void ? 'void' : 'wrong';
    }, "scalar,list\nvoid");

    check_case("$mode: dispatch sizes and scalar domains", q{
        for my $size (1, 15, 16, 17, 65) {
            for my $kind (qw(integer float string)) {
                for my $default (0, 1) {
                    my @values = map {
                        $kind eq 'integer' ? 2 * $_
                      : $kind eq 'float'   ? 2 * $_ + 0.5
                      : sprintf 'key%04d', 2 * $_
                    } 1 .. $size;
                    my $source = 'sub { my ($value) = @_; case ($value) {';
                    for my $index (0 .. $#values) {
                        my $literal = $kind eq 'string'
                            ? '"' . $values[$index] . '"' : $values[$index];
                        $source .= "match ($literal) { $index }";
                    }
                    $source .= 'match (_) { -1 }' if $default;
                    $source .= '} }';
                    my $matcher = eval $source;
                    die $@ if $@;
                    for my $index (0 .. $#values) {
                        my $got = $matcher->($values[$index]);
                        die "$kind/$size/$default hit $index"
                            unless defined($got) && $got == $index;
                    }
                    # Below minimum, between keys, and above maximum.
                    my @misses = $kind eq 'string'
                        ? ('key0000', 'key0003', 'key9999')
                        : $kind eq 'float' ? (0.5, 3.5, 2*$size + 2.5)
                        : (0, 3, 2*$size + 2);
                    for my $miss (@misses) {
                        my $got = $matcher->($miss);
                        die "$kind/$size/$default miss $miss"
                            unless $default ? defined($got) && $got == -1
                                            : !defined($got);
                    }
                }
            }
        }
        say 'all hits and misses correct';
    }, 'all hits and misses correct');
}

check_case('nested constants preserve the scalar kind', q{
    for my $value ([1], ['1'], {x => 1}, {x => '1'}) {
        case ($value) {
            match (['1'])   { say 'array string' }
            match ([1])     { say 'array number' }
            match ({x=>'1'}) { say 'hash string' }
            match ({x=>1})   { say 'hash number' }
        }
    }
}, "array number\narray string\nhash number\nhash string");

check_case('numeric strings: padding, whitespace, exponents and invalid text', q{
    for my $value ('7', '0007', ' 7 ', '-0', '7.0', '1e3', '.5', 'A', '') {
        case ($value) {
            match (IntStr($original))   { say "integer:$original" }
            match (FloatStr($original)) { say "float:$original" }
            match (_)                  { say 'neither' }
        }
    }
}, "integer:7\ninteger:0007\ninteger: 7 \ninteger:-0\nfloat:7.0\n"
   . "float:1e3\nfloat:.5\nneither\nneither");

check_case('value-kind criteria distinguish undef, scalars and references', q{
    for my $value (undef, '', 0, '0', [], {}, sub {}, bless({}, 'Object')) {
        case ($value) {
            match (ObjectVal()) { say 'object' }
            match (RefVal()) { say 'reference' }
            match (DefinedVal()) { say 'defined scalar' }
            match (ScalarVal()) { say 'undefined scalar' }
        }
    }
}, "undefined scalar\ndefined scalar\ndefined scalar\ndefined scalar\n"
   . "reference\nreference\nreference\nobject");

check_case('boolean values and ordinary truth values remain distinct', q{
    use builtin qw(true false);
    for my $value (true, false, undef, '', '0', 0, 'yes', [], 1 < 2) {
        case ($value) {
            match (true)  { say 'boolean true' }
            match (false) { say 'boolean false' }
            match (TRUE)  { say 'truthy' }
            match (FALSE) { say 'falsey' }
        }
    }
}, "boolean true\nboolean false\nfalsey\nfalsey\nfalsey\nfalsey\n"
   . "truthy\ntruthy\nboolean true");

for my $criterion (qw(Int Float Num)) {
    my $text = $criterion eq 'Int' ? '1' : '1.5';
    check_case("$criterion: strings stay strings after numeric use", '
        my $value = "' . $text . '";
        my $number = 0 + $value;
        case ($value) {
            match (' . $criterion . '()) { say "wrong" }
            match (_) { say "string" }
        }
    ', 'string');
}

for my $criterion (qw(IntStr FloatStr NumStr)) {
    my $text = $criterion eq 'IntStr' ? '0007' : '0007.5';
    check_case("Strict($criterion): numeric cache cannot bypass spelling", '
        my $value = "' . $text . '";
        for (1 .. 2) {
            case ($value) {
                match (Strict(' . $criterion . '())) { say "wrong" }
                match (_) { say "rejected" }
            }
            my $number = 0 + $value;
        }
    ', "rejected\nrejected");
}

check_case('nested typed capture fetches its tied source once', q{
    package Changing {
        sub TIESCALAR { bless [0], shift }
        sub FETCH { ++$_[0][0] == 1 ? 1 : 'changed' }
    }
    my @values = (0);
    tie $values[0], 'Changing';
    case (\@values) {
        match ([Int($captured)]) { say $captured }
    }
    say tied($values[0])->[0];
}, "1\n1");

check_case('user guard reads remain separate from matcher reads', q{
    package Changing {
        sub TIESCALAR { bless [0], shift }
        sub FETCH { ++$_[0][0] }
    }
    my $value;
    tie $value, 'Changing';
    case ($value) {
        match (1 if $value == 2) { say $value }
    }
    say tied($value)->[0];
}, "3\n3");

check_case('sparse slots match undef without filling source holes', q{
    my @values;
    $values[2] = 1;
    case (\@values) {
        match ([undef, undef, 1]) { say 'hit' }
        match (_) { say 'miss' }
    }
    say exists($values[0]) || exists($values[1]) ? 'filled' : 'sparse';
}, "hit\nsparse");

check_case('sparse tail captures preserve length and undef values', q{
    my @values;
    $values[2] = 1;
    case (\@values) {
        match ([@tail]) {
            say join ',', map { defined($_) ? $_ : 'undef' } @tail;
        }
        match (_) { say 'miss' }
    }
    say exists($values[0]) ? 'filled' : 'sparse';
}, "undef,undef,1\nsparse");

check_case('open searches may start at a sparse undef slot', q{
    my @values;
    $values[2] = 'end';
    case (\@values) {
        match ([..., undef, 'end', ...]) { say 'hit' }
        match (_) { say 'miss' }
    }
}, 'hit');

for my $shape ('{a}', '{$key=>1}', '{a=>...}') {
    check_case("malformed hash shape $shape is rejected at compile time", '
        my $compiled = eval q{sub {
            case ({a=>1}) { match (' . $shape . ') { 1 } }
        }};
        say $@ && !$compiled ? "rejected" : "accepted";
    ', 'rejected');
}

for my $shape ('[1,...,2]', '[@rest,1]', '[@first,@second]',
               '[@rest:-1]', '[@rest:4294967296]', 'constant(1)',
               'Strict(Num())', 'Strict(Int())', 'Strict(Float())',
               'RefVal(1)', 'NumEq($target)') {
    check_case("unsupported shape $shape is rejected before execution", '
        sub constant { 1 }
        my $compiled = eval q{sub {
            case ([]) { match (' . $shape . ') { 1 } }
        }};
        say $@ && !$compiled ? "rejected" : "accepted";
    ', 'rejected');
}

check_case('slurp minimum checks below, at and above the boundary', q{
    for my $subject ([1], [1,2], [1,2,3], [1,2,3,4]) {
        case ($subject) {
            match ([1,@tail:2]) { say join ',', @tail }
            match (_) { say 'short' }
        }
    }
}, "short\nshort\n2,3\n2,3,4");

check_case('scalar-reference shapes do not try to copy CODE bodies', q{
    case (sub {}) {
        match (\$value) { say 'wrong' }
        match (_) { say 'not a scalar reference' }
    }
}, 'not a scalar reference');

check_case('nested reference shapes bind the scalar referent', q{
    my $number = 42;
    my $reference = \$number;
    case (\$reference) {
        match (\\\\$value) { say $value }
    }
}, '42');

for my $upgrade_subject (0, 1) {
    check_case("concat preserves character semantics, upgrade=$upgrade_subject", '
        my $subject = chr(233) . "tail";
        my $prefix = chr(233);
        utf8::upgrade(' . ($upgrade_subject ? '$subject' : '$prefix') . ');
        case ($subject) with ($prefix) {
            match ($prefix . $suffix) { say $suffix }
            match (_) { say "miss" }
        }
    ', 'tail');
}

check_case('concat does not implicitly stringify a numeric subject', q{
    for my $subject (123, '123') {
        case ($subject) {
            match ('1' . $tail) { say "tail=$tail" }
            match (_) { say 'not a string' }
        }
    }
}, "not a string\ntail=23");

check_case('ordinary scope exit releases a case subject', q{
    use builtin qw(weaken);
    my $weak;
    {
        my $subject = bless {}, 'Lifetime';
        $weak = $subject;
        weaken($weak);
        case ($subject) { match (_) { } }
    }
    say defined($weak) ? 'retained' : 'released';
}, 'released');

check_case('native field view is released when field matching throws', q{
    use feature 'class';
    no warnings 'experimental::class';
    use builtin qw(weaken);
    package Throws {
        use overload '""' => sub { die "field error\n" }, fallback => 1;
    }
    class Holder { field $value :param }
    my $weak;
    {
        my $value = bless {}, 'Throws';
        $weak = $value;
        weaken($weak);
        my $subject = Holder->new(value => $value);
        eval { case ($subject) { match (Holder {'$value'=>'text'}) { } } };
        die 'wrong exception' unless $@ eq "field error\n";
        # Isolate the field-view leak from the separate subject ownership bug.
        undef $subject;
        undef $value;
    }
    say defined($weak) ? 'retained' : 'released';
}, 'released');

check_case('generator suspension preserves a clause binding', q{
    use generator;
    my $process = gen {
        case (['ok', 42]) {
            match (['ok', $number]) {
                yield $number;
                yield $number + 1;
            }
        }
    };
    say $process->();
    say $process->();
    my @end = $process->();
    say scalar @end;
}, "42\n43\n0");

check_case('case-local as and with names do not require namespaces', q{
    my ($subject, $wanted, $calls) = ('outer', 'outer', 0);
    case (['ok', 3] as $subject)
    with ('ok' as $wanted, ++$calls + 2 as $version) {
        match ([$wanted, $version]) { say join ',', @$subject }
    }
    say "$subject,$wanted,$calls";
}, "ok,3\nouter,outer,1");

check_case('failed guards do not refresh direct pins', q{
    my $wanted = 1;
    case ([1]) {
        match ([^$wanted] if do { $wanted = 2; 0 }) { die 'wrong clause' }
        match ([^$wanted]) { say 'snapshot' }
    }
    say $wanted;
}, "snapshot\n2");

check_case('recursive clauses keep bindings independent', q{
    sub descend {
        my ($depth) = @_;
        case ([$depth]) {
            match ([$number] if $number > 0) {
                my $inner = descend($number - 1);
                return "$number:$inner:$number";
            }
            match ([0]) { return 'zero' }
        }
    }
    say descend(2);
}, '2:1:zero:1:2');

check_case('guard suspension preserves tentative captures', q{
    use generator;
    my $process = gen {
        case ([7]) {
            match ([$number] if yield($number)) { yield $number + 1 }
            match (_) { yield 'default' }
        }
    };
    say $process->();
    say $process->(1);
    my @end = $process->();
    say scalar @end;
}, "7\n8\n0");

check_case('false resumption of a generator guard selects the next clause', q{
    use generator;
    my $process = gen {
        case ([7]) {
            match ([$number] if yield($number)) { yield 'wrong' }
            match ([$other]) { yield $other + 2 }
        }
    };
    say $process->();
    say $process->(0);
    my @end = $process->();
    say scalar @end;
}, "7\n9\n0");

check_case('closures from repeated slurp matches retain independent tails', q{
    my @closures;
    for my $value ([1, 2], [3, 4]) {
        case ($value) {
            match ([$first, @tail]) { push @closures, sub { ($first, @tail) } }
        }
    }
    say join ',', $_->() for @closures;
}, "1,2\n3,4");

check_case('regex captures restore after an exception from a guard', q{
    'outer' =~ /(?<outside>outer)/;
    eval {
        case ('inner') {
            match (/(?<inside>inner)/ if die "guard error\n") { }
        }
    };
    die 'wrong exception' unless $@ eq "guard error\n";
    say "$1,$+{outside}";
}, 'outer,outer');

check_case('regex backtracking publishes captures from the winning candidate', q{
    case (['a1', 'bad', 'a2', 'b2']) {
        match ([..., /a(?<first>\d)/, /b(?<second>\d)/, ...]) {
            say "$first,$second,$1";
        }
    }
}, '2,2,2');

check_case('concat byte captures do not retain a partial UTF-8 flag', q{
    my $text = chr(233);
    utf8::upgrade($text);
    use bytes;
    case ($text) {
        match ("\xc3" . $tail) {
            say unpack('H*', $tail);
            say utf8::is_utf8($tail) ? 'wrong flag' : 'bytes';
        }
    }
}, "a9\nbytes");

check_case('concat calls subject and pinned stringification only once', q{
    package Text {
        our $calls = 0;
        use overload '""' => sub { ++$calls; $_[0][0] }, fallback => 1;
    }
    my $subject = bless ['prefix_tail'], 'Text';
    my $prefix = bless ['prefix_'], 'Text';
    case ($subject) with ($prefix) {
        match ($prefix . $tail) { say $tail }
    }
    say $Text::calls;
}, "tail\n2");

check_case('computed scalar values use the same kind rules as literals', q{
    sub text { '1' }
    sub number { 1 }
    for my $value (1, '1') {
        case ($value) {
            match (text()) { say 'string' }
            match (number()) { say 'number' }
        }
    }
}, "number\nstring");

for my $qualifier ('', 'Box ') {
    check_case("${qualifier}hash shapes distinguish missing keys from undef", q{
        package Values {
            our ($exists, $fetches) = (0, 0);
            sub TIEHASH { bless {}, shift }
            sub EXISTS { ++$exists; $_[1] eq 'present' }
            sub FETCH { ++$fetches; undef }
            sub FIRSTKEY { 'present' }
            sub NEXTKEY { undef }
        }
        tie my %values, 'Values';
        my $subject = bless \%values, 'Box';
    } . '
        case ($subject) {
            match (' . $qualifier . '{missing=>undef,...}) { say "wrong" }
            match (_) { say "absent" }
        }
        case ($subject) {
            match (' . $qualifier . '{missing=>undef}) { say "wrong" }
            match (_) { say "absent" }
        }
        case ($subject) {
            match (' . $qualifier . '{present=>undef,...}) { say "present" }
        }
        case ($subject) {
            match (' . $qualifier . '{present=>undef}) { say "present" }
        }
        say "$Values::exists,$Values::fetches";
    ', "absent\nabsent\npresent\npresent\n4,2");
}

check_case('false guard advances clauses rather than restarting open search', q{
    my @seen;
    case ([1, 2, 3]) {
        match ([..., $item, ...] if do { push @seen, $item; $item == 2 }) {
            say 'wrong retry';
        }
        match (_) { say 'next clause' }
    }
    say join ',', @seen;
}, "next clause\n1");

check_case('recursive regex shapes follow ordinary regex capture behavior', q{
    my (@ordinary, @shapes);
    sub ordinary {
        my ($n) = @_;
        "$n" =~ /(?<digits>\d+)/;
        my $digits = $+{digits};
        ordinary($n - 1) if $n;
        push @ordinary, "$digits,$1";
    }
    sub shaped {
        my ($n) = @_;
        case ("$n") {
            match (/(?<digits>\d+)/) {
                shaped($n - 1) if $n;
                push @shapes, "$digits,$1";
            }
        }
    }
    ordinary(2);
    shaped(2);
    say join(';', @ordinary) eq join(';', @shapes) ? 'same' : 'different';
}, 'same');

check_case('tail bindings copy source slots in both directions', q{
    my $source = [1, 2, 3];
    my $saved;
    case ($source) {
        match ([1, @tail:2]) {
            $tail[0] = 20;
            $source->[2] = 30;
            say join ',', @tail;
            say join ',', @$source;
            $saved = sub { join ',', @tail };
            delete $tail[1];
        }
    }
    @$source = (9);
    say $saved->();
}, "20,3\n1,2,30\n20");

check_case('tail copies preserve reference identity without slot aliases', q{
    my $object = bless { value => 1 }, 'Box';
    my $source = [$object];
    case ($source) {
        match ([@tail]) {
            say $tail[0] == $object ? 'same object' : 'wrong';
            $tail[0]{value} = 2;
            $tail[0] = undef;
            say $source->[0]{value};
        }
    }
}, "same object\n2");

check_case('tail copies fetch tied elements once and do not retain magic', q{
    package Values {
        our ($fetches, $stores) = (0, 0);
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { ++$fetches; $_[1] + 10 }
        sub STORE { ++$stores }
    }
    tie my @source, 'Values';
    case (\@source) {
        match ([@tail]) {
            say join ',', @tail;
            say join ',', @tail;
            $tail[0] = 99;
        }
    }
    say "$Values::fetches,$Values::stores";
}, "10,11\n10,11\n2,0");

check_case('a false guard cannot modify source slots through its tail', q{
    my $source = [1, 2];
    case ($source) {
        match ([@tail] if do { $tail[0] = 99; 0 }) { say 'wrong' }
        match ([1, 2]) { say 'unchanged' }
    }
}, 'unchanged');

check_case('pinned equality distinguishes undef from empty strings', q{
    for my $pair ([undef, ''], ['', undef], ['a', 'b'],
                 [undef, undef], ['', ''], [0, '0']) {
        my ($pin, $subject) = @$pair;
        case ($subject) with ($pin) {
            match ($pin) { say 'equal' }
            match (_) { say 'different' }
        }
        case ($subject) {
            match (^$pin) { say 'equal' }
            match (_) { say 'different' }
        }
    }
    case (undef) {
        match (undef) { say 'literal undef' }
    }
}, join("\n", (('different') x 6), (('equal') x 6), 'literal undef'));

check_case('pattern callbacks cannot destroy retained captures', q{
    package Box { sub DESTROY { } }
    my @values = (bless({}, 'Box'), 1);
    sub remove_first { delete $values[0]; 1 }
    case (\@values) {
        match ([RefVal($captured), remove_first()]) { say ref $captured }
    }
}, 'Box');

check_case('pattern calls retain the current scalar and nested container', q{
    my @values = ([1, 2]);
    sub remove_container { $values[0] = undef; 1 }
    case (\@values) {
        match ([[remove_container(), 2]]) { say 'hit' }
        match (_) { say 'miss' }
    }
}, 'hit');

check_case('exception releases captures retained before a callback', q{
    package Box {
        our $destroyed = 0;
        sub DESTROY { ++$destroyed }
    }
    my @values = (bless({}, 'Box'), 1);
    sub fail { delete $values[0]; die "expected\n" }
    eval {
        case (\@values) {
            match ([RefVal($captured), fail()]) { say 'wrong' }
        }
    };
    say $@ eq "expected\n" ? 'caught' : 'wrong error';
    say $Box::destroyed;
}, "caught\n1");

check_case('open arrays check literal anchors before fetching captures', q{
    package Values {
        our @reads;
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 3 }
        sub FETCH { push @reads, $_[1]; (10, 20, 42)[$_[1]] }
    }
    tie my @values, 'Values';
    case (\@values) {
        match ([..., $x, 42, ...]) { say $x }
    }
    say join ',', @Values::reads;
}, "20\n1,2,1");

check_case('literal failure skips pattern calls and capture-only reads', q{
    sub unexpected { die 'must not call' }
    case ([1, 9]) {
        match ([unexpected(), 7]) { say 'wrong' }
        match (_) { say 'miss' }
    }
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { die 'capture fetched' if $_[1] == 0; 9 }
    }
    tie my @values, 'Values';
    case (\@values) {
        match ([$x, 7]) { say 'wrong' }
        match (_) { say 'miss' }
    }
}, "miss\nmiss");

check_case('nested captures wait for outer constraints', q{
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 1 }
        sub FETCH { die 'nested capture fetched' }
    }
    tie my @values, 'Values';
    sub reject { 0 }
    case ([\@values, 1]) {
        match ([[$x], reject()]) { say 'wrong' }
        match (_) { say 'miss' }
    }
}, 'miss');

check_case('constraint observations are reused when publishing captures', q{
    package Values {
        our $reads = 0;
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { ++$reads; 12 }
    }
    tie my @values, 'Values';
    case (\@values) {
        match ([Int($x), Int($y)] if $x == $y) { say $x }
    }
    say $Values::reads;
}, "12\n2");

check_case('literal hash constraints precede capture-only fetches', q{
    package Values {
        our @reads;
        sub TIEHASH { bless {}, shift }
        sub EXISTS { 1 }
        sub FETCH { push @reads, $_[1]; $_[1] eq 'tag' ? 'yes' : 12 }
    }
    tie my %values, 'Values';
    case (\%values) {
        match ({ value => $x, tag => 'yes', ... }) { say $x }
    }
    say join ',', @Values::reads;
}, "12\ntag,value");

check_case('owner grows across rejected pinned candidates', q{
    my @values = (1 .. 1001);
    my $last = 1001;
    case (\@values) with ($last) {
        match ([..., Int($x), $last, ...]) { say $x }
    }
}, '1000');

check_case('wildcards do not fetch array elements', q{
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { die 'wildcard fetched' if $_[1] == 0; 42 }
    }
    tie my @values, 'Values';
    case (\@values) { match ([_, 42]) { say 'hit' } }
}, 'hit');

check_case('retained constraints observe in-place changes but survive deletion', q{
    my @values = (1, 1, 2);
    sub change { $values[0] = 2; 1 }
    case (\@values) {
        match ([Int($x), change(), 2]) { say $x }
    }
}, '2');

check_case('array candidates do not chase callback appends', q{
    my @values = (1, 2);
    our $calls = 0;
    sub extend { ++$calls; push @values, 99; 99 }
    case (\@values) {
        match ([..., extend(), ...]) { say 'wrong' }
        match (_) { say 'miss' }
    }
    say $calls;
}, "miss\n2");

check_case('callback exceptions after owned regex and concat captures unwind', q{
    sub fail { die "expected\n" }
    for (1 .. 20) {
        eval {
            case (['abc', 'prefix_tail', 1]) {
                match ([/(?<word>abc)/, 'prefix_' . $tail, fail()]) {
                    die 'wrong';
                }
            }
        };
        die 'wrong error' unless $@ eq "expected\n";
    }
    say 'caught';
}, 'caught');

check_case('many deferred captures use independent metadata and grow safely', q{
    my $pattern = join ',', map { '$v' . $_ } 1 .. 100;
    my $code = 'case ([1 .. 100]) { match ([' . $pattern
        . ']) { say $v1 + $v100 } }';
    eval $code;
    die $@ if $@;
}, '101');

check_case('duplicate regex names select source order across scheduling ranks', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        case (['a', ['b']]) {
            match ([/(?<x>a)/, [/(?<x>b)/]]) { say "$x,$+{x}" }
        }
    };
    die $@ if $@;
    say @warnings == 1
        && $warnings[0] =~ /only the first regex maps/ ? 'warned' : 'wrong warning';
}, "a,a\nwarned");

check_case('nonparticipating first regex capture survives reordered execution', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        case (['a', ['b']]) {
            match ([/(?:a|(?<x>z))/, [/(?<x>b)/]]) {
                say defined($x) ? 'wrong' : 'undef';
            }
        }
    };
    die $@ if $@;
    say scalar @warnings;
}, "undef\n1");

check_case('reordered regex names preserve original capture across candidates', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        case (['no', ['b'], 'a', ['b']]) {
            match ([..., /(?<x>a)/, [/(?<x>b)/], ...]) { say $x }
        }
    };
    die $@ if $@;
    say scalar @warnings;
}, "a\n1");

check_case('scalar equality matrix agrees for both pin forms', q{
    my $array = [];
    my $hash = {};
    my @values = (undef, '', 0, '0', 1, '1', 'word', $array, $hash);
    for my $a (@values) {
        for my $b (@values) {
            my $expected = !defined($a) || !defined($b)
                ? !defined($a) && !defined($b)
                : ref($a) || ref($b)
                    ? ref($a) && ref($b) && $a == $b : $a eq $b;
            my $actual = do { case ($b) {
                match (^$a) { 1 } match (_) { 0 }
            } };
            die 'caret mismatch' if !!$actual != !!$expected;
            my $pinned = do { case ($b) with ($a) {
                match ($a) { 1 } match (_) { 0 }
            } };
            die 'pinned mismatch' if !!$pinned != !!$expected;
        }
    }
    say '81 pairs';
}, '81 pairs');

check_case('shape call failures propagate exception objects unchanged', q{
    my $error = bless {}, 'Failure';
    sub fail { die $error }
    eval { case ([1]) { match ([fail()]) { die 'wrong' } } };
    say ref($@) eq 'Failure' && $@ == $error ? 'same exception' : 'wrong';
}, 'same exception');

for my $qualifier ('', 'Box ') {
    check_case("${qualifier}hash wildcard checks presence without fetching", q{
        package Values {
            our $exists = 0;
            sub TIEHASH { bless {}, shift }
            sub EXISTS { ++$exists; $_[1] eq 'present' }
            sub FETCH { die 'wildcard fetched' }
        }
        tie my %values, 'Values';
        my $subject = bless \%values, 'Box';
    } . '
        case ($subject) {
            match (' . $qualifier . '{present => _, ...}) { say "hit" }
        }
        case ($subject) {
            match (' . $qualifier . '{absent => _, ...}) { say "wrong" }
            match (_) { say "miss" }
        }
        say $Values::exists;
    ', "hit\nmiss\n2");
}

check_case('empty shapes distinguish container kinds and reject contents', q{
    for my $v ([], {}, [undef], {a => undef}, undef, '', 0, sub {}) {
        case ($v) {
            match ([]) { say 'array' }
            match ({}) { say 'hash' }
            match (_)  { say 'miss' }
        }
    }
}, "array\nhash\n" . join("\n", ('miss') x 6));

check_case('empty shapes nest and participate in open-array searches', q{
    case ([1, [[], {}], 2]) {
        match ([..., [[], {}], ...]) { say 'nested' }
    }
    case ({a => [], b => {}}) {
        match ({a => [], b => {}}) { say 'fields' }
    }
    case ([]) {
        match ([] if 0) { say 'wrong' }
        match ([])     { say 'guard' }
    }
}, "nested\nfields\nguard");

check_case('class-qualified empty shapes require the exact class and kind', q{
    for my $v (bless([], 'Box'), bless({}, 'Box'),
               bless([1], 'Box'), bless({a => 1}, 'Box'),
               bless([], 'Other'), [], {}) {
        case ($v) {
            match (Box []) { say 'array' }
            match (Box {}) { say 'hash' }
            match (_)      { say 'miss' }
        }
    }
}, "array\nhash\n" . join("\n", ('miss') x 5));

check_case('empty native-class shapes use the field view', q{
    use feature 'class';
    no warnings 'experimental::class';
    class Empty {}
    class Full { field $x = 1; }
    case (Empty->new) {
        match (Empty {}) { say 'empty' }
    }
    case (Full->new) {
        match (Full {}) { say 'wrong' }
        match (_)       { say 'full' }
    }
}, "empty\nfull");

check_case('empty tied shapes inspect size or keys but never fetch values', q{
    {
        package Array;
        sub TIEARRAY { bless [$_[1]], $_[0] }
        sub FETCHSIZE { $_[0][0] }
        sub FETCH { die 'unexpected array FETCH' }
        package Hash;
        sub TIEHASH { bless [$_[1]], $_[0] }
        sub FIRSTKEY { $_[0][0] ? 'key' : undef }
        sub NEXTKEY { undef }
        sub FETCH { die 'unexpected hash FETCH' }
    }
    for my $size (0, 1) {
        tie my @a, 'Array', $size;
        tie my %h, 'Hash', $size;
        for my $v (\@a, \%h) {
            case ($v) {
                match ([]) { say 'array' }
                match ({}) { say 'hash' }
                match (_)  { say 'full' }
            }
        }
    }
}, "array\nhash\nfull\nfull");

check_case('empty shape constraints skip unrelated capture fetches', q{
    { package Value; sub TIEARRAY { bless {}, shift }
      sub FETCHSIZE { 2 }
      sub FETCH { die 'capture fetched' if $_[1] == 0; [1] } }
    tie my @values, 'Value';
    case (\@values) {
        match ([$x, []]) { say 'wrong' }
        match (_)       { say 'miss' }
    }
}, 'miss');

check_case('duplicate capture declarations are rejected across shape kinds', q{
    for my $shape (
        '[$x, $x]',
        '[$x, "x" . $x]',
        '["x" . $x, $x]',
        '{a => $x, b => [$x]}',
        '[RefVal($x), $x]',
        '[ObjectVal($x), ObjectVal($x)]',
        '[DefinedVal($x), DefinedVal($x)]',
        '[Int($x), Float($x)]',
        '[[ @tail ], [ @tail ]]',
        '[Box {a => $x}, Box {b => $x}]',
    ) {
        eval 'case ([]) { match (' . $shape . ') { die "executed" } }';
        die "wrong error: $@" unless
            $@ =~ /duplicate capture [\$\@](?:x|tail) in a match clause/;
        say 'rejected';
    }
}, join("\n", ('rejected') x 10));

check_case('pins, guards, and separate clauses can reuse variable names', q{
    my $x = 'a';
    case (['a', 'a']) with ($x) {
        match ([$x, $x]) { say 'with' }
    }
    case (['a', 'a']) {
        match ([^$x, ^$x]) { say 'caret' }
    }
    case (['a', 'a']) {
        match ([$x, $y] if $x eq $y) { say "$x,$x" }
    }
    case (['b']) {
        match ([$x] if 0) { say 'wrong' }
        match ([$x])      { say $x }
    }
}, "with\ncaret\na,a\nb");

check_case('duplicate captures report the name and offending source line', q{
    use utf8;
    eval qq{#line 40 "duplicate-shape"
case ([]) {
    match ([\$résultat,
            \$résultat]) { }
}};
    die "wrong diagnostic: $@" unless
        $@ =~ /duplicate capture \$résultat in a match clause at duplicate-shape line 42/;
    say 'located';
}, 'located');

check_case('scalar and array captures with the same basename are distinct', q{
    case ([1, 2, 3]) {
        match ([$items, @items]) { say "$items:@items" }
    }
}, '1:2 3');

done_testing();
