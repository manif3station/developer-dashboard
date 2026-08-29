package Developer::Dashboard::StreamDrain;

use strict;
use warnings;

our $VERSION = '4.29';

use Exporter 'import';

our @EXPORT_OK = qw(_drain_ready_handle);

# Exported into the consuming package rather than called as a class method, so
# every call site reads as $self->_drain_ready_handle(...) and Perl resolves it
# through the consumer's own symbol table. That matters: it keeps the helper
# mockable from each consumer's tests, which is the seam DD-615 learned to
# preserve the hard way - a helper called as a plain function resolves in the
# module it lives in, so a test patching only the consumer stops reaching it.

# _drain_ready_handle($selector, $handle)
# Reads one ready handle from a select set, exactly as the two inline readers
# did before this was shared.
# Input: the IO::Select object and the handle it reported ready.
# Output: a reference to the bytes read, or undef when the handle is finished -
#         in which case it has already been removed from the selector and closed.
sub _drain_ready_handle {
    my ( $self, $selector, $handle ) = @_;

    my $chunk = '';
    my $read = sysread( $handle, $chunk, 8192 );

    # DELIBERATELY CONFLATES ERROR WITH END OF FILE, because that is what both
    # callers did before this extraction and this change preserves behaviour.
    #
    # sysread returns undef on error and 0 at EOF. Treating them alike means an
    # interrupted read - EINTR, which is retryable - closes the handle and
    # silently truncates the child's output. That is a real defect, it is filed
    # as DD-678, and it is NOT fixed here: folding a correctness fix into a
    # refactor makes it impossible to tell afterwards which change caused what.
    # t/162 pins the current behaviour so the fix has to arrive as a visible
    # failing assertion rather than as a side effect.
    #
    # PageRuntime does not share this helper precisely because its own drain
    # already guards EINTR, and adopting this one would be a regression.
    if ( !defined $read || $read == 0 ) {    # uncoverable condition left
        $selector->remove($handle);
        close $handle;
        return;
    }

    return \$chunk;
}

1;

__END__

=head1 NAME

Developer::Dashboard::StreamDrain - the one place a ready handle is read

=head1 PURPOSE

Provide the single inner drain step shared by the dashboard's inline
streaming child-process readers: read up to 8192 bytes from a handle that
L<IO::Select> reported ready, and, when the handle is finished, remove it from
the select set and close it.

=head1 WHY IT EXISTS

C<SkillDispatcher> and C<SkillManager> each carried a byte-identical copy of
this step. Copy-paste was provable rather than inferred: both files carried the
same authored C<# uncoverable condition left> annotation on the same end-of-file
branch. A bug in that step therefore had to be found and fixed twice, and this
project has already paid that cost - the C<$?>-pollution defect in the same
family of readers was fixed through two unrelated ticket series before a
standing sweep was added to police it.

It exists as its own module rather than as a method on a base class because the
callers share nothing else: they differ in timeout policy, in what a timeout
does, in where the bytes go, and in where the exit status comes from. Only this
step is common, and only this step is shared.

C<PageRuntime> is deliberately NOT a consumer. It had already factored its own
read out and guards C<EINTR>, which this helper does not; importing this one
would replace a correct drain with a defective one.

=head1 WHEN TO USE

Whenever a caller reads a child process's C<stdout> or C<stderr> through
C<IO::Select> and wants the established end-of-file handling. Callers keep
their own loop, their own timeout policy and their own accounting.

=head1 HOW TO USE

    use Developer::Dashboard::StreamDrain qw(_drain_ready_handle);

    while ( my @ready = $selector->can_read ) {
        for my $handle (@ready) {
            my $chunk_ref = $self->_drain_ready_handle( $selector, $handle )
                or next;                      # finished: already removed and closed
            # ... route ${$chunk_ref} wherever this caller sends it ...
        }
    }

=head1 WHAT USES IT

C<Developer::Dashboard::SkillDispatcher> and
C<Developer::Dashboard::SkillManager>.

=head1 EXAMPLES

Routing by file descriptor, as C<SkillDispatcher> does when it tees a child's
output through to the real C<STDOUT> and C<STDERR>:

    my $chunk_ref = $self->_drain_ready_handle( $selector, $fh ) or next;
    if ( fileno($fh) == $stdout_fd ) {
        print STDOUT ${$chunk_ref};
        $stdout_text .= ${$chunk_ref};
        next;
    }

Accumulating into a per-handle slot, as C<SkillManager> does while reporting
progress a line at a time:

    my $chunk_ref = $self->_drain_ready_handle( $selector, $handle ) or next;
    my $slot = $target_for{ fileno($handle) };
    ${$slot} .= ${$chunk_ref} if $slot;

=cut
