package Developer::Dashboard::StreamDrain;

use strict;
use warnings;

our $VERSION = '6.30';

use Exporter 'import';

our @EXPORT_OK = qw(_drain_ready_handle _drain_child_streams_windows);

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

    # THREE OUTCOMES, NOT TWO (DD-678). sysread returns 0 at end of file and
    # undef on error, and this used to take the same branch for both - which
    # meant an interrupted read closed the handle and silently truncated the
    # child's output.
    #
    # Perl does not install handlers with SA_RESTART, and sysread bypasses the
    # :perlio layer that would otherwise retry, so EINTR reaches us. SkillManager
    # raises SIGALRM itself, so this is not hypothetical for its own reader.
    #
    # PageRuntime does not share this helper - it already had its own EINTR-aware
    # drain, and adopting a non-aware one would have been a regression. That is
    # now moot in the sense that this one is aware too, but the separation stays:
    # t/163 fails by design if anybody migrates it.
    #
    # AND IT HANDLES EINTR DIFFERENTLY, deliberately, because the two helpers
    # return different things. PageRuntime's _drain_saved_ajax_ready_handle
    # returns a STATUS and can therefore do an early "return 1" on EINTR -
    # phrased without backticks or the literal exit-status variable, because
    # t/159's guard sweeps RAW SOURCE and cannot tell code from the commentary
    # about it: a backtick pair anywhere in a sub body reads as a command
    # substitution, and naming that variable at all reads as an unguarded use.
    # Both fire from inside a comment. Filed as DD-693. Handing
    # control back so its outer select loop calls again. This one returns DATA,
    # with undef meaning "the handle is finished", so returning undef on EINTR
    # would reproduce the very defect being fixed. The retry therefore happens
    # here, in a loop.
    #
    # That loop cannot busy-spin: sysread on a blocking handle waits for bytes or
    # a signal, so between interrupts it is asleep, not turning. It is the
    # standard EINTR idiom, not a poll.
    my $chunk = '';
    my $read;

    while (1) {
        $read = sysread( $handle, $chunk, 8192 );
        last if defined $read;

        # RETRYABLE. The read was interrupted before any bytes moved; the child
        # is not finished and the handle is still live.
        next if $!{EINTR};

        # A GENUINE ERROR, which is neither retryable nor end of file. It is
        # surfaced rather than swallowed - reporting it as EOF is what hid this
        # class of failure in the first place - and then the handle is finished,
        # because a handle we cannot read is not one we can keep selecting on.
        warn "reading a ready child handle failed: $!\n";
        last;
    }

    if ( !defined $read || $read == 0 ) {
        $selector->remove($handle);
        close $handle;
        return;
    }

    return \$chunk;
}

# _drain_child_streams_windows($stdout, $stderr, $on_chunk)
# Drains two open3 pipe handles on Windows, where IO::Select cannot see
# pipes at all: select() there only works for real sockets, so a can_read
# loop over pipe handles returns at once with nothing ready and the child's
# output is silently lost (the doctor hook proved it live: the hook ran and
# exited 0, but its stdout arrived empty). PeekNamedPipe cannot reach these
# handles either - GetOsFHandle returns nothing for an open3 pipe (also
# proved live) - so read each pipe from its own thread with a blocking
# sysread, exactly as PageRuntime does for saved Ajax, and hand each chunk
# to the callback in arrival order, so callers keep their streaming
# behaviour. The callback runs in the caller's thread, never in a reader.
# Input: stdout handle, stderr handle, callback taking ($is_stdout, $chunk).
# Output: 1 when both handles were drained to end of file, 0 when threads
# were unavailable, in which case the caller falls back to its select loop
# (the pre-existing behaviour, never a new failure).
sub _drain_child_streams_windows {
    my ( $self, $stdout, $stderr, $on_chunk ) = @_;

    my $have_threads = eval { require threads; require Thread::Queue; 1 };
    return 0 if !$have_threads;

    my $queue = Thread::Queue->new;
    # No queue limit: with a limit, a reader can block in enqueue while the
    # caller has stopped dequeuing (it is in the join), which deadlocks; and
    # if the drain then dies before the join, the queue is destroyed while a
    # reader is blocked, which panics the interpreter with COND_DESTROY on
    # Windows. The caller dequeues continuously, and child output here is
    # small, so an unbounded queue is safe.
    my @readers;
    for my $stream ( [ 1, $stdout ], [ 0, $stderr ] ) {
        my ( $is_stdout, $fh ) = @{$stream};
        push @readers, threads->create(
            sub {
                my ( $events, $reader, $stream_is_stdout ) = @_;
                while (1) {
                    my $chunk = '';
                    my $bytes = sysread( $reader, $chunk, 8192 );
                    if ( !defined $bytes ) {
                        next if $!{EINTR};
                        my $error = "$!";
                        $events->enqueue( 'R' . $stream_is_stdout . pack( 'N', length($error) ) . $error );
                        last;
                    }
                    last if $bytes == 0;
                    $events->enqueue( 'D' . $stream_is_stdout . pack( 'N', length($chunk) ) . $chunk );
                }
                $events->enqueue( 'C' . $stream_is_stdout );
                return 1;
            },
            $queue, $fh, $is_stdout,
        );
    }

    my %open_stream = ( 1 => 1, 0 => 1 );
    my $drain_error;
    eval {
        while ( keys %open_stream ) {
            my $event = $queue->dequeue_timed(0.25);
            next if !defined $event;
            my $type      = substr( $event, 0, 1 );
            my $is_stdout = substr( $event, 1, 1 );
            if ( $type eq 'C' ) {
                delete $open_stream{$is_stdout};
                next;
            }
            next if $type ne 'D' && $type ne 'R';
            my $length  = unpack 'N', substr( $event, 2, 4 );
            my $payload = substr( $event, 6 );
            next if length($payload) != $length;
            if ( $type eq 'R' ) {
                warn "reading a child handle failed: $payload\n";
                next;
            }
            $on_chunk->( $is_stdout, $payload );
        }
        1;
    } or do {
        $drain_error = $@;
    };
    # Always join the readers before the queue goes out of scope. If this
    # drain dies before the join, the queue is destroyed while a reader is
    # still blocked on it, and the interpreter panics with COND_DESTROY on
    # Windows instead of returning the error.
    $_->join for @readers;
    die $drain_error if defined $drain_error;

    return 1;
}

1;

__END__

=head1 NAME

Developer::Dashboard::StreamDrain - the one place a ready handle is read

=head1 PURPOSE

Provide the single inner drain step shared by the dashboard's inline
streaming child-process readers: read up to 8192 bytes from a handle that
L<IO::Select> reported ready, and, when the handle is finished, remove it from
the select set and close it. On Windows, where L<IO::Select> cannot see pipes
at all, provide the matching whole-loop drain that reads each child pipe from
its own thread with a blocking C<sysread> instead, so the same callers do not
silently lose the child's output there.

=head1 WHY IT EXISTS

C<SkillDispatcher> and C<SkillManager> each carried a byte-identical copy of
this step. Copy-paste was provable rather than inferred: both files carried the
same authored coverage-exemption annotation on the same end-of-file
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
would replace a correct drain with a defective one. It also already has its own
Windows path (reader threads feeding a queue) - the pattern the whole-loop
drain here follows - so it never needed this module's version either.

=head1 WHEN TO USE

Whenever a caller reads a child process's C<stdout> or C<stderr> through
C<IO::Select> and wants the established end-of-file handling. Callers keep
their own loop, their own timeout policy and their own accounting. On Windows,
call C<_drain_child_streams_windows> instead of the select loop: C<select()>
there only works for real sockets, so a C<can_read> loop over pipe handles
returns at once with nothing ready and the child's output is lost.

=head1 HOW TO USE

    use Developer::Dashboard::StreamDrain qw(_drain_ready_handle);

    while ( my @ready = $selector->can_read ) {
        for my $handle (@ready) {
            my $chunk_ref = $self->_drain_ready_handle( $selector, $handle )
                or next;                      # finished: already removed and closed
            # ... route ${$chunk_ref} wherever this caller sends it ...
        }
    }

On Windows, use the whole-loop drain instead of the select loop above:

    use Developer::Dashboard::StreamDrain qw(_drain_child_streams_windows);

    my $drained = $self->_drain_child_streams_windows(
        $stdout, $stderr,
        sub {
            my ( $is_stdout, $chunk ) = @_;
            # ... route $chunk wherever this caller sends it ...
        },
    );
    # $drained is 1 when both streams reached end of file, 0 when the
    # Windows primitive was unavailable - fall back to the select loop.

=head1 WHAT USES IT

C<Developer::Dashboard::SkillDispatcher>,
C<Developer::Dashboard::SkillManager>, and the C<d2> switchboard's own
C<_run_command_hook_streaming> (which runs per-command and main-gate hooks
before the command itself).

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
