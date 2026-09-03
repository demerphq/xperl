package iterator;

use v5.40;

sub RUNNING   () { 1 }
sub COMPLETED () { 2 }
sub FAILED    () { 3 }

1;

=head1 NAME

iterator - lifecycle protocol for callable iterators

=head1 DESCRIPTION

The C<iterator> package provides the lifecycle protocol used by callable
iterators.  An iterator is a blessed code reference, so it remains callable
with the normal Perl syntax.

The constructor marks the code reference as C<RUNNING>.  The iterator body can
    use C<__SUB__> to set its state before returning its final value:

    my $it = iterator->new(sub {
        state $i = 0;
        __SUB__->set_state(iterator::COMPLETED) if $i == $#items;
        return $items[$i++];
    });

The state describes whether another call may produce a value.  A completed
iterator may still return its final value on the call that marks it completed.
An empty return is therefore not, by itself, evidence of exhaustion.

The C<generator> package is a specialized iterator with additional
continuation state.  Generator state is managed by the generator runtime and
cannot be changed with C<set_state>.

The usual spelling for the current callable is C<__SUB__>.  Its fully
qualified spelling, C<CORE::__SUB__>, is also available when the unqualified
keyword is not enabled.

=cut
