use v5.40;
use B ();
our ($left, $right, @left, @right);
sub report ($label) {
    my $gp_same = B::svref_2object(\*left)->GP == B::svref_2object(\*right)->GP ? 1 : 0;
    my $sv_same = \$left == \$right;
    my $arrays = join('/', $left[0], $right[0]);
    my $observed;
    { local $left = 'nested local'; $observed = $right }
    say "$label: GP equal=$gp_same; scalar referent equal=$sv_same; arrays=$arrays; right inside local left=$observed";
}
{
    local *left;
    local *right = *left;
    $left = 'owner';
    @left = ('host left array');
    report('one GP for the parked scalar group');
}
{
    local *left;
    local *right;
    my $owner = 'owner';
    *left = \$owner;
    *right = \$owner;
    @left = ('host left array');
    @right = ('host right array');
    report('two GPs with the same scalar referent');
}
