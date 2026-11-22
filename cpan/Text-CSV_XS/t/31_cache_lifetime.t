use strict;
use warnings;

use Test::More;
use Text::CSV_XS;

# Vary the object size so retaining a cache value crosses hash growth
# boundaries. Rebuilding the cache must keep the value, not its entry slot.
for my $size (0 .. 80) {
    my $csv = Text::CSV_XS->new ({ binary => 1 });
    $csv->{"padding_$_"} = $_ for 1 .. $size;

    $csv->{undef_str} = "NULL";
    $csv->{comment_str} = "#";
    $csv->{_types} = pack "CCC", Text::CSV_XS::IV (),
        Text::CSV_XS::PV (), Text::CSV_XS::NV ();
    delete @{$csv}{qw(_CACHE _UNDEF_STR_HELD _COMMENT_STR_HELD _TYPES_HELD)};

    ok ($csv->parse ("2.55,text,3.75"), "parse after cache growth at size $size");
    is_deeply ([$csv->fields ()], [2, "text", 3.75],
        "cached types survive at size $size");

    ok ($csv->combine (undef, "text", 3.75), "combine at size $size");
    like ($csv->string (), qr/^NULL,/, "cached undef string survives at size $size");

    my $input = "# ignored\n1,text,2\n";
    open my $fh, "<", \$input or die "Cannot open scalar input: $!";
    is_deeply ($csv->getline ($fh), [1, "text", 2],
        "cached comment string survives at size $size");
}

done_testing;
