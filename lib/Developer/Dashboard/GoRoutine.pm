package Developer::Dashboard::GoRoutine;

use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(reftype);
use Filter::Simple;

our $VERSION = '6.30';

our @EXPORT = qw(
    go
    wait_all
    share
    channel
    spawn
    process_running
    process_exited
    wait_process
    terminate_process
);

require Developer::Dashboard::HtmlEscape;
die "Developer::Dashboard XS bundle is not loaded; GoRoutine requires its native extension\n"
    if !$Developer::Dashboard::HtmlEscape::XS_LOADED;

# -------------------------------------------------------------------------
# User syntax
# -------------------------------------------------------------------------
#
# The Perl function go(&;$) is the primitive used for:
#
#     go sub { ... };
#
# A small code-only source filter adds declaration syntax that an ordinary
# Perl prototype cannot express (mixed scalar/array/hash aliases), and the
# named-call shorthand:
#
#     share my ($a, @b, %c) = ...;
#     share $a, @b, %c;
#     go abc(1, 2);
#
# Filter::Simple gives this transformer only executable Perl code; strings,
# regexes, POD, comments, and heredocs are protected from rewriting.

sub _skip_ws {
    my ($src, $pos) = @_;
    my $len = length $src;
    $pos++ while $pos < $len && substr($src, $pos, 1) =~ /\s/;
    return $pos;
}

sub _matching_delim {
    my ($src, $pos) = @_;
    my %close = ('(' => ')', '[' => ']', '{' => '}');
    my $open = substr($src, $pos, 1);
    return unless exists $close{$open};

    my @stack = ($close{$open});
    my $len = length $src;
    for (my $i = $pos + 1; $i < $len; $i++) {
        my $ch = substr($src, $i, 1);
        if (exists $close{$ch}) {
            push @stack, $close{$ch};
            next;
        }
        if ($ch eq $stack[-1]) {
            pop @stack;
            return $i unless @stack;
        }
    }
    return;
}

sub _statement_end {
    my ($src, $pos) = @_;
    my %close = ('(' => ')', '[' => ']', '{' => '}');
    my @stack;
    my $len = length $src;

    for (my $i = $pos; $i < $len; $i++) {
        my $ch = substr($src, $i, 1);
        if (exists $close{$ch}) {
            push @stack, $close{$ch};
            next;
        }
        if (@stack && $ch eq $stack[-1]) {
            pop @stack;
            next;
        }
        return $i if $ch eq ';' && !@stack;
    }
    return;
}

sub _variable_refs {
    my ($text) = @_;
    my @vars;
    pos($text) = 0;

    while (1) {
        $text =~ /\G\s*/gc;
        last if pos($text) >= length($text);

        $text =~ /\G([\$\@\%]\s*(?:[A-Za-z_]\w*(?:::\w+)*))/gc
            or die "share() expects simple scalar, array, or hash variables";

        my $v = $1;
        $v =~ s/\s+//g;
        push @vars, $v;

        $text =~ /\G\s*/gc;
        last if pos($text) >= length($text);
        $text =~ /\G,/gc
            or die "share() expects a comma-separated variable list";
    }

    return @vars;
}

sub _refs_expr {
    return join(', ', map { '\\' . $_ } @_);
}

sub _rewrite_share_at {
    my ($src, $start) = @_;
    my $after = $start + length('share');
    my $p = _skip_ws($src, $after);

    # share my ...
    if (substr($src, $p, 2) eq 'my'
        && substr($src, $p + 2, 1) !~ /[A-Za-z0-9_]/) {

        my $q = _skip_ws($src, $p + 2);
        my $first = substr($src, $q, 1);

        # Keep the existing lvalue implementation for the common scalar form.
        # The separate open/share rewrite handles:
        #
        #     open share my $fh, '<', $file;
        if ($first eq '$') {
            return;
        }

        # Group declaration: share my ($a, @b, %c) = ...;
        if ($first eq '(') {
            my $rparen = _matching_delim($src, $q);
            die "unterminated share my (...) declaration" unless defined $rparen;

            my $inside = substr($src, $q + 1, $rparen - $q - 1);
            my @vars = _variable_refs($inside);
            my $semi = _statement_end($src, $rparen + 1);
            die "share declaration must end with a semicolon" unless defined $semi;

            my $tail = substr($src, $rparen + 1, $semi - $rparen - 1);
            my $replacement = 'my (' . join(', ', @vars) . '); '
                . 'Developer::Dashboard::GoRoutine::_share_many('
                . _refs_expr(@vars) . ');';

            if ($tail =~ /^\s*=\s*(.*)\z/s) {
                $replacement .= ' (' . join(', ', @vars) . ') = ' . $1 . ';';
            }
            elsif ($tail !~ /^\s*\z/s) {
                die "unsupported text after share my (...) declaration";
            }

            return ($semi + 1, $replacement);
        }

        # Aggregate declaration: share my @a = (...); / share my %h = (...);
        if ($first eq '@' || $first eq '%') {
            substr($src, $q) =~ /\A([\@\%]\s*(?:[A-Za-z_]\w*(?:::\w+)*))/
                or die "invalid shared aggregate declaration";
            my $rawvar = $1;
            my $var = $rawvar;
            $var =~ s/\s+//g;
            my $var_end = $q + length($rawvar);
            my $semi = _statement_end($src, $var_end);
            die "share declaration must end with a semicolon" unless defined $semi;
            my $tail = substr($src, $var_end, $semi - $var_end);

            my $replacement = 'my ' . $var . '; '
                . 'Developer::Dashboard::GoRoutine::_share_many(\\' . $var . ');';

            if ($tail =~ /^\s*=\s*(.*)\z/s) {
                $replacement .= ' ' . $var . ' = ' . $1 . ';';
            }
            elsif ($tail !~ /^\s*\z/s) {
                die "unsupported text after shared aggregate declaration";
            }

            return ($semi + 1, $replacement);
        }

        return;
    }

    # Existing variables.  A single scalar keeps using share(\$), because it
    # is already a valid normal Perl function call and can occur in expression
    # position.  Aggregate or multi-variable forms need rewriting.
    my $semi = _statement_end($src, $p);
    return unless defined $semi;
    my $body = substr($src, $p, $semi - $p);

    return if $body =~ /^\s*\$\s*[A-Za-z_]\w*(?:::\w+)*(?:\s*=\s*.*)?\z/s;

    if ($body =~ /^\s*[\$\@\%]/) {
        my @vars = _variable_refs($body);
        my $replacement = 'Developer::Dashboard::GoRoutine::_share_many('
            . _refs_expr(@vars) . ');';
        return ($semi + 1, $replacement);
    }

    return;
}

sub _rewrite_go_at {
    my ($src, $start) = @_;
    my $p = _skip_ws($src, $start + length('go'));

    # Preserve the original and most common form.
    return if substr($src, $p, 3) eq 'sub'
        && substr($src, $p + 3, 1) !~ /[A-Za-z0-9_]/;

    # named sub call: go abc(...)
    substr($src, $p) =~ /\A((?:[A-Za-z_]\w*)(?:::\w+)*)/
        or return;
    my $name = $1;
    my $q = _skip_ws($src, $p + length($name));
    return unless substr($src, $q, 1) eq '(';
    my $rparen = _matching_delim($src, $q);
    die "unterminated go $name(...) call" unless defined $rparen;

    my $args = substr($src, $q + 1, $rparen - $q - 1);
    my $replacement = 'Developer::Dashboard::GoRoutine::_go_call(\\&'
        . $name;
    $replacement .= ', ' . $args if $args =~ /\S/;
    $replacement .= ')';

    return ($rparen + 1, $replacement);
}


sub _rewrite_open_share_at {
    my ($src, $start) = @_;
    my $p = _skip_ws($src, $start + length('open'));
    return unless substr($src, $p, 5) eq 'share'
        && substr($src, $p + 5, 1) !~ /[A-Za-z0-9_]/;

    my $q = _skip_ws($src, $p + 5);
    return unless substr($src, $q, 2) eq 'my'
        && substr($src, $q + 2, 1) !~ /[A-Za-z0-9_]/;

    my $vpos = _skip_ws($src, $q + 2);
    substr($src, $vpos) =~ /\A(\$\s*(?:[A-Za-z_]\w*(?:::\w+)*))/
        or return;
    my $rawvar = $1;
    my $var = $rawvar;
    $var =~ s/\s+//g;
    my $after_var = $vpos + length($rawvar);
    my $comma = _skip_ws($src, $after_var);
    return unless substr($src, $comma, 1) eq ',';

    my $semi = _statement_end($src, $comma + 1);
    die "open share declaration must end with a semicolon" unless defined $semi;

    my $rest = substr($src, $comma + 1, $semi - $comma - 1);
    my $replacement = 'my ' . $var . '; open ' . $var . ',' . $rest . '; '
        . 'Developer::Dashboard::GoRoutine::_share_many(\\' . $var . ');';

    return ($semi + 1, $replacement);
}

sub _rewrite_user_syntax {
    my ($src) = @_;
    my $out = '';
    my $pos = 0;
    my $len = length $src;

    while ($pos < $len) {
        my $prev = $pos ? substr($src, $pos - 1, 1) : '';
        if ($prev !~ /[A-Za-z0-9_:>\$\@%&]/
            && substr($src, $pos) =~ /\A\b(open|share|go)\b/) {
            my $kw = $1;
            my @r = $kw eq 'open'
                ? _rewrite_open_share_at($src, $pos)
                : $kw eq 'share'
                    ? _rewrite_share_at($src, $pos)
                    : _rewrite_go_at($src, $pos);

            if (@r) {
                my ($end, $replacement) = @r;
                $out .= $replacement;
                $pos = $end;
                next;
            }
        }

        $out .= substr($src, $pos, 1);
        $pos++;
    }

    return $out;
}

# Perl parses:
#
#     share my $x = VALUE;
#
# as:
#
#     (share my $x) = VALUE;
#
# The lvalue attribute lets share() install the shared slot first; the normal
# assignment that follows then initializes the C-backed value.  Existing
# scalar values are preserved as well, so "my $x = 123; share $x" works.
sub share (\$) : lvalue {
    my ($slot) = @_;

    die "share() called on an already tied scalar" if tied($$slot);

    $$slot;
}

sub _share_many {
    for my $ref (@_) {
        my $type = reftype($ref) || '';

        if ($type eq 'SCALAR' || $type eq 'REF') {
            share $$ref;
            next;
        }

        if ($type eq 'ARRAY') {
            die "share() called on an already tied array" if tied @$ref;
            next;
        }

        if ($type eq 'HASH') {
            die "share() called on an already tied hash" if tied %$ref;
            next;
        }

        die "share() expects scalar, array, or hash variables";
    }

    return;
}

sub _go_call {
    my ($code, @args) = @_;
    die "go named-call target is not a CODE reference" unless ref($code) eq 'CODE';

    # Arguments are evaluated in the caller before this function is entered,
    # matching normal function-call and Go-style launch semantics.  The
    # closure and its captured argument list are then registered with the engine by the Perl go().
    return go(sub { $code->(@args) });
}

FILTER_ONLY code => sub {
    $_ = Developer::Dashboard::GoRoutine::_rewrite_user_syntax($_);
};

# -------------------------------------------------------------------------
# Engine: single-threaded event loop (Perl side)
# -------------------------------------------------------------------------
#
# The C engine (GoRoutineEvent.h) only waits: timers, IO readiness, and
# process exits. This side owns the routine registry, dispatches callbacks
# on the main thread, and owns the channel queues. There is one interpreter,
# so a routine record is a plain Perl hashref and a shared value is a plain
# Perl value. Nothing here uses fork, threads.pm, or perl_clone.

my %ROUTINES;
my $NEXT_ROUTINE_ID = 0;
my $_LOAD_PID = $$; # forked children must not drain the parent's queue

sub _routine_record {
    my ($id) = @_;
    return $ROUTINES{$id};
}

sub _is_finished_state {
    my ($state) = @_;
    return $state eq 'done' || $state eq 'killed' || $state eq 'timed_out'
        || $state eq 'exited' || $state eq 'failed';
}

# _finish_routine($id, $state, $error)
# Marks a routine finished. A repeating routine that completed normally
# goes back to pending instead (its triggers stay registered in the C
# engine); a repeating routine that failed or exited stops repeating.
# Removes the routine's triggers unless it repeats. Drops the record once
# nobody can observe it any more (its handle was destroyed).
sub _finish_routine {
    my ($id, $state, $error) = @_;
    my $rec = $ROUTINES{$id};
    return unless $rec;
    if ($rec->{repeating} && $state eq 'done') {
        $rec->{state} = 'pending';
        return;
    }
    $rec->{state} = $state;
    $rec->{finished_at} = _ev_now();
    $rec->{error} = $error if defined $error;
    _ev_cancel($id);
    delete $ROUTINES{$id} unless $rec->{handle_alive};
    return;
}

# _cancel_routine($id, $kind) -- $kind is 'killed' or 'timed_out'.
# Pending: cancels at once. Running: sets the cooperative flag, which the
# dispatch honours when the callback returns. Finished: a no-op.
# Returns true when the routine was pending or running.
sub _cancel_routine {
    my ($id, $kind) = @_;
    my $rec = $ROUTINES{$id};
    return 0 unless $rec;
    return 0 if _is_finished_state($rec->{state});
    if ($rec->{state} eq 'running') {
        $rec->{cancel_requested} = 1;
        $rec->{cancel_kind} = $kind;
        return 1;
    }
    _finish_routine($id, $kind);
    return 1;
}

# _set_routine_timeout($id, $seconds)
# Timeouts are checked in Perl, in pump(), not by an engine timer: the
# engine has no per-kind cancel, so replacing a timeout would mean
# cancelling every trigger for the routine and re-registering the ones
# that have not fired yet. A Perl-side deadline is simpler and fires just
# as promptly, because pump() bounds its wait by the nearest timeout.
# $seconds 0 clears the timeout.
sub _set_routine_timeout {
    my ($id, $seconds) = @_;
    my $rec = $ROUTINES{$id};
    return unless $rec;
    return if _is_finished_state($rec->{state});
    if ($seconds == 0) {
        $rec->{timeout_at} = undef;
    }
    else {
        $rec->{timeout_at} = _ev_now() + $seconds;
    }
    return;
}

# _routine_handle_destroyed($id)
# The handle is gone but the routine continues (its callback is held by
# the record, not by the handle). Drop the record once the routine is
# finished and nobody can observe it any more.
sub _routine_handle_destroyed {
    my ($id) = @_;
    my $rec = $ROUTINES{$id};
    return unless $rec;
    $rec->{handle_alive} = 0;
    delete $ROUTINES{$id} if _is_finished_state($rec->{state});
    return;
}

# go($code, \%opts)
# Schedules a callback on the main thread and returns a routine handle.
# The callback runs when the engine pumps and one of its triggers fires.
# With no trigger it runs at the next pump tick. Options:
#   after => $seconds    one-shot timer
#   every => $seconds    repeating timer (the routine repeats)
#   readable => $fh|$fd  IO readiness (fd on Unix, socket on Windows)
#   writable => $fh|$fd  IO readiness
#   repeat => 1          keep an IO trigger registered after it fires
#   pid => $pid          process exit
# A callback MUST be short and non-blocking: it runs on the main thread,
# so a blocking callback stalls the whole process.
sub go (&;$) {
    my ($code, $opts) = @_;
    die "go() expects a code reference" unless ref($code) eq 'CODE';
    $opts = {} unless defined $opts;
    die "go() options must be a hash reference" unless ref($opts) eq 'HASH';

    my $id = ++$NEXT_ROUTINE_ID;
    my $now = _ev_now();
    my $rec = {
        id               => $id,
        cb               => $code,
        state            => 'pending',
        started_at       => $now,
        finished_at      => undef,
        timeout_at       => undef,
        cancel_requested => 0,
        cancel_kind      => undef,
        repeating        => 0,
        handle_alive     => 1,
        error            => undef,
    };
    $ROUTINES{$id} = $rec;

    my $triggered = 0;
    if (defined $opts->{after}) {
        _ev_add_timer($id, $now + $opts->{after}, 0, 0);
        $triggered = 1;
    }
    if (defined $opts->{every}) {
        _ev_add_timer($id, $now + $opts->{every}, $opts->{every}, 0);
        $rec->{repeating} = 1;
        $triggered = 1;
    }
    for my $dir (qw(readable writable)) {
        next unless defined $opts->{$dir};
        my $given = $opts->{$dir};
        my $fd = ref($given) ? fileno($given) : $given;
        die "go() $dir trigger needs a filehandle or a file descriptor"
            unless defined($fd) && $fd =~ /\A\d+\z/;
        _ev_add_io($id, $fd, $dir eq 'readable' ? 1 : 0,
            $dir eq 'writable' ? 1 : 0, $opts->{repeat} ? 1 : 0);
        $rec->{repeating} = 1 if $opts->{repeat};
        $triggered = 1;
    }
    if (defined $opts->{pid}) {
        _ev_add_pid($id, $opts->{pid});
        $triggered = 1;
    }
    _ev_add_timer($id, $now, 0, 0) unless $triggered;

    return bless { id => $id }, 'Developer::Dashboard::GoRoutine::Routine';
}

# _dispatch_routine($id)
# Runs one pending routine's callback on the main thread. Returns true
# when a callback ran. A due id for a routine that is no longer pending
# (cancelled, timed out, or already finished) is ignored. The callback is
# invoked through _ev_invoke_callback, which scopes exit() to the routine.
sub _dispatch_routine {
    my ($id) = @_;
    my $rec = $ROUTINES{$id};
    return 0 unless $rec && $rec->{state} eq 'pending';
    $rec->{state} = 'running';
    my $err = _ev_invoke_callback($rec->{cb});
    $rec = $ROUTINES{$id};
    return 0 unless $rec;
    if (!defined $err) {
        if ($rec->{cancel_requested}) {
            _finish_routine($id, $rec->{cancel_kind} || 'killed');
        }
        else {
            _finish_routine($id, 'done');
        }
    }
    elsif ($err =~ /__GOROUTINE_EXIT__/) {
        _finish_routine($id, 'exited');
    }
    else {
        _finish_routine($id, 'failed', $err);
    }
    return 1;
}

# pump($timeout_seconds)
# Runs one engine iteration: waits for the next trigger (or at most
# $timeout_seconds; undef waits until the next trigger), then dispatches
# every due routine. Timeouts are checked here, in Perl. Returns how many
# due ids and timeouts were processed; 0 means the engine had nothing
# registered at all.
sub pump {
    my ($timeout) = @_;
    my $wait_ms;
    if (!defined $timeout) {
        $wait_ms = -1;
    }
    else {
        $wait_ms = int($timeout * 1000);
        $wait_ms = 0 if $wait_ms < 0;
    }

    # Bound the wait by the nearest routine timeout, so a timeout fires
    # promptly even when the next engine trigger is far away.
    my $now = _ev_now();
    for my $rec (values %ROUTINES) {
        next if _is_finished_state($rec->{state});
        next unless defined $rec->{timeout_at};
        # Round UP: truncating to whole milliseconds would wait up to 1ms
        # short of the deadline and the check below would miss the timeout.
        my $until = int(($rec->{timeout_at} - $now) * 1000);
        $until = $until < 0 ? 0 : $until + 1;
        $wait_ms = $until if $wait_ms < 0 || $until < $wait_ms;
    }

    my @due = _ev_wait($wait_ms);
    my $progress = 0;
    for my $signed (@due) {
        $progress++;
        if ($signed < 0) {
            # Engine timeout trigger. The Perl side implements timeouts
            # itself (see _set_routine_timeout), but a timeout trigger
            # arriving here is honoured the same way.
            my $id = -$signed;
            my $rec = $ROUTINES{$id};
            next unless $rec;
            if ($rec->{state} eq 'pending') {
                $rec->{cancel_kind} = 'timed_out';
                _finish_routine($id, 'timed_out');
            }
            elsif ($rec->{state} eq 'running') {
                $rec->{cancel_requested} = 1;
                $rec->{cancel_kind} = 'timed_out';
            }
        }
        else {
            _dispatch_routine($signed);
        }
    }

    # Perl-side timeout check.
    $now = _ev_now();
    for my $rec (values %ROUTINES) {
        next if _is_finished_state($rec->{state});
        next unless defined $rec->{timeout_at};
        next unless $rec->{timeout_at} <= $now;
        $progress++;
        if ($rec->{state} eq 'pending') {
            $rec->{cancel_kind} = 'timed_out';
            _finish_routine($rec->{id}, 'timed_out');
        }
        elsif ($rec->{state} eq 'running') {
            $rec->{cancel_requested} = 1;
            $rec->{cancel_kind} = 'timed_out';
        }
    }

    return $progress;
}

# wait_all()
# Pumps until no finite routine is pending. Repeating routines are
# services, not tasks: they are not waited for, or this would wait
# forever. A routine that is running (this was called from inside a
# callback) is not waited for either, or it would wait for itself.
sub wait_all {
    while (1) {
        my @pending = grep { $_->{state} eq 'pending' && !$_->{repeating} }
            values %ROUTINES;
        last unless @pending;
        my $progress = pump(undef);
        last if $progress == 0;
    }
    return;
}

# channel($capacity)
# Creates a channel object. With no argument it is unbuffered, matching
# an unbuffered Go channel. channel(N) creates a buffered channel of
# capacity N.
sub channel {
    my ($capacity) = @_;
    $capacity = 0 unless defined $capacity;
    die "channel() capacity must be a non-negative integer"
        unless $capacity =~ /\A\d+\z/;
    return bless {
        queue            => [],
        closed           => 0,
        capacity         => 0 + $capacity,
        sender_waiting   => 0,
        sender_value     => undef,
        receiver_waiting => 0,
    }, 'Developer::Dashboard::GoRoutine::Channel';
}

# Shutdown drain. The C atexit drain ran after global destruction, when
# calling Perl code is unsafe; an END block runs while the interpreter can
# still execute code, on the main thread. Repeating (service) routines are
# cancelled first, because they never finish on their own. Finite routines
# are then drained with a 30 second bound, so a stuck routine cannot hang
# process exit; after the bound the process exits as it used to, leaving
# still-running routines behind. Forked children do not drain the
# parent's queue. POSIX::_exit still skips END blocks, as before.
END {
    return if $$ != $_LOAD_PID;
    for my $id (keys %ROUTINES) {
        my $rec = $ROUTINES{$id};
        next unless $rec && $rec->{repeating};
        next if _is_finished_state($rec->{state});
        _cancel_routine($id, 'killed');
    }
    my $deadline = _ev_now() + 30;
    while (1) {
        my @pending = grep { $_->{state} eq 'pending' } values %ROUTINES;
        last unless @pending;
        my $remaining = $deadline - _ev_now();
        last if $remaining <= 0;
        pump($remaining);
    }
}

package Developer::Dashboard::GoRoutine::Channel;

use strict;
use warnings;

sub _check {
    my ($self) = @_;
    die "invalid channel handle" unless ref($self) && exists $self->{queue};
    return $self;
}

# send($value)
# Sends a value. Buffered: blocks (by pumping) only while the buffer is
# full. Unbuffered: blocks (by pumping) until a receiver takes the value.
# Sending on a closed channel throws an exception.
sub send {
    my ($self, $value) = @_;
    $self->_check;
    die "send on closed channel" if $self->{closed};
    if ($self->{capacity} > 0) {
        while (@{ $self->{queue} } >= $self->{capacity}) {
            die "send on closed channel" if $self->{closed};
            Developer::Dashboard::GoRoutine::pump(0.05);
            die "send on closed channel" if $self->{closed};
        }
        push @{ $self->{queue} }, $value;
        return $self;
    }
    if ($self->{receiver_waiting}) {
        push @{ $self->{queue} }, $value;
        return $self;
    }
    $self->{sender_waiting} = 1;
    $self->{sender_value} = $value;
    while ($self->{sender_waiting}) {
        die "send on closed channel" if $self->{closed};
        Developer::Dashboard::GoRoutine::pump(0.05);
        die "send on closed channel" if $self->{closed};
    }
    return $self;
}

# receive()
# Receives a value, blocking (by pumping) until one arrives or the channel
# closes. A queued value is returned first; a sender already offering a
# value is taken next. Receiving from a closed, drained channel returns
# undef in scalar context or (undef, 0) in list context; a successful
# list-context receive returns ($value, 1).
sub receive {
    my ($self) = @_;
    $self->_check;
    if (@{ $self->{queue} }) {
        my $value = shift @{ $self->{queue} };
        return wantarray ? ($value, 1) : $value;
    }
    if ($self->{sender_waiting}) {
        my $value = delete $self->{sender_value};
        $self->{sender_waiting} = 0;
        return wantarray ? ($value, 1) : $value;
    }
    return wantarray ? (undef, 0) : undef if $self->{closed};
    $self->{receiver_waiting} = 1;
    while (1) {
        last if @{ $self->{queue} } || $self->{sender_waiting} || $self->{closed};
        Developer::Dashboard::GoRoutine::pump(0.05);
    }
    $self->{receiver_waiting} = 0;
    if (@{ $self->{queue} }) {
        my $value = shift @{ $self->{queue} };
        return wantarray ? ($value, 1) : $value;
    }
    if ($self->{sender_waiting}) {
        my $value = delete $self->{sender_value};
        $self->{sender_waiting} = 0;
        return wantarray ? ($value, 1) : $value;
    }
    return wantarray ? (undef, 0) : undef;
}

sub close {
    my ($self) = @_;
    $self->_check;
    $self->{closed} = 1;
    return $self;
}

sub is_closed {
    my ($self) = @_;
    $self->_check;
    return $self->{closed} ? 1 : 0;
}

sub size {
    my ($self) = @_;
    $self->_check;
    return 0 + @{ $self->{queue} };
}

sub capacity {
    my ($self) = @_;
    $self->_check;
    return 0 + $self->{capacity};
}

package Developer::Dashboard::GoRoutine::Routine;

use strict;
use warnings;

sub _rec {
    my ($self) = @_;
    die "invalid go routine handle" unless ref($self) && exists $self->{id};
    my $rec = Developer::Dashboard::GoRoutine::_routine_record($self->{id});
    die "invalid go routine handle" unless $rec;
    return $rec;
}

sub is_running {
    my ($self) = @_;
    return $self->_rec->{state} eq 'running' ? 1 : 0;
}

sub age {
    my ($self) = @_;
    my $rec = $self->_rec;
    my $end = $rec->{finished_at} // Developer::Dashboard::GoRoutine::_ev_now();
    return 0 + ($end - $rec->{started_at});
}

sub kill {
    my ($self) = @_;
    my $rec = $self->_rec;
    return Developer::Dashboard::GoRoutine::_cancel_routine($rec->{id}, 'killed') ? 1 : 0;
}

sub timeout {
    my ($self, $seconds) = @_;
    die "timeout() requires a non-negative number of seconds"
        unless defined($seconds)
            && $seconds =~ /\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
            && 0 + $seconds == 0 + $seconds
            && abs(0 + $seconds) < 1e308;

    my $rec = $self->_rec;
    Developer::Dashboard::GoRoutine::_set_routine_timeout($rec->{id}, 0 + $seconds);
    return $self;
}

sub status {
    my ($self) = @_;
    return $self->_rec->{state};
}

sub is_killed {
    my ($self) = @_;
    my $status = $self->status;
    return ($status eq 'killed' || $status eq 'timed_out') ? 1 : 0;
}

# cancel_requested()
# True when kill or a timeout has asked this routine to stop while it was
# running. A callback that yields (pumps, or returns) should check this
# and wind down; the engine cannot interrupt code that never yields.
sub cancel_requested {
    my ($self) = @_;
    return $self->_rec->{cancel_requested} ? 1 : 0;
}

# Releasing the handle does not stop the routine: the record (and its
# callback) is held by the registry, not by the handle, so the routine
# keeps running until it finishes or is cancelled.
sub DESTROY {
    my ($self) = @_;
    return unless ref($self) && exists $self->{id};
    Developer::Dashboard::GoRoutine::_routine_handle_destroyed($self->{id});
    return;
}

package Developer::Dashboard::GoRoutine;

1;

__END__

=head1 NAME

Developer::Dashboard::GoRoutine - go-style routines on a C event loop with shared Perl data

=head1 PURPOSE

This module provides the Developer Dashboard concurrency API: Perl
goroutines on a single-threaded C event loop, shared Perl values, channels,
and native operating system process management. It keeps those facilities
under the existing C<Developer::Dashboard::*> namespace while loading their
implementation from the distribution's XS bundle.

=head1 WHY IT EXISTS

Dashboard collectors, services, and tools need concurrent work and managed
subprocesses across supported operating systems. Perl's direct C<fork()> is
not portable to Windows and does not provide shared Perl references between
workers. This module supplies explicit APIs for both in-process routines and
independent child processes, with errors surfaced to the caller.

=head1 WHEN TO USE

Use C<go> for a Perl callback that should run asynchronously, C<share> or
C<channel> when workers need to exchange supported values, and C<spawn> when
an independent operating-system process is required. Use C<wait_all> before
program exit whenever outstanding routines must finish. Choose C<spawn>
instead of C<go> when the work must run as a separate process rather than on
the main thread.

=head1 HOW TO USE

Import C<go>, C<share>, C<channel>, and C<wait_all> from this module, or call
their fully-qualified names. Shared values support normal Perl dereferencing;
channels provide blocking send and receive operations and can be closed to
wake waiters. Use the returned routine handle to inspect, time out, or cancel
a routine. For subprocesses, pass an argument array and an optional hash of
working-directory, environment, stream-redirection, or process-group options
to C<spawn>, then inspect, wait for, or terminate the returned process id.

=head1 WHAT USES IT

RuntimeManager uses the process API for collector and web-service supervision.
Collector workers use goroutines and shared state to coordinate refresh work.
Other Dashboard Perl code can import this module directly when it needs
portable concurrent callbacks, cross-worker values, channels, or subprocess
lifecycle control.

=head1 SYNOPSIS

    use Developer::Dashboard::GoRoutine;

    share my $state = {
        count => 0,
        jobs  => [],
    };

    my $worker = go sub {
        $state->{count}++;
        push $state->{jobs}->@*, { id => 1, status => 'done' };
    };

    $worker->timeout(10);
    wait_all();

    print $state->{count};

    my $chan = channel();

    go sub {
        my $value = $chan->receive;
        print $value;
    };

    $chan->send(123);
    wait_all();

=head1 DESCRIPTION

C<go> schedules a Perl callback on the main thread and returns a routine
handle.  It does not call C<fork()>, does not use Perl's C<threads> module,
and does not clone the interpreter: a single-threaded C event loop (timers,
IO readiness, process exits) invokes the callback on the main thread when
one of its triggers fires.  C<go(sub { ... }, \%opts)> adds a trigger:
C<after> for a one-shot timer, C<every> for a repeating timer, C<readable> /
C<writable> for IO readiness, C<pid> for process exit.  The handle provides
C<age>, C<is_running>, C<kill>, C<timeout>, C<status>, C<is_killed>, and
C<cancel_requested>.  A fresh routine reports status C<pending> until the
engine dispatches it.

A callback MUST be short and non-blocking: it runs on the main thread, so a
callback that blocks (sleep, a blocking read, an infinite loop) stalls the
whole process.  Callers that need to wait use a trigger instead of blocking.

Cancellation is cooperative.  C<kill> cancels a pending routine at once; for
a running routine it sets a flag the callback can observe with
C<cancel_requested> and wind down.  An opaque XS/C call that never returns
cannot be forcibly torn down safely.

Inside a go routine, Perl C<exit> is scoped to that routine: it unwinds the
routine instead of terminating the whole process.  C<exit> in the main
interpreter keeps normal Perl semantics.

C<share my $x = VALUE> creates one process-wide value that is visible to the
main interpreter and every routine.  There is only one interpreter, so the
value IS the plain Perl value: scalars, hashes, arrays, nested combinations,
scalar/reference chains, CODE, GLOB/filehandles, IO references, regular
expressions, formats, lvalue/version scalar references, Perl 5.40 field
objects, and ordinary blessed data-backed objects are all supported, with
normal Perl dereferencing and filehandle syntax retained.  C<share> returns
the value unchanged; it exists so code written for the old threaded engine
keeps working, and so a variable can be marked as shared for readers.

Scalar read/modify/write operations such as C<++>, C<-->, C<+=>, C<-=>,
C<*=>, C</=>, C<%=> and C<.=> are atomic with respect to other routines,
because callbacks never run at the same time: a routine only runs when the
engine dispatches it on the main thread.  Hash and array structural
operations are likewise safe without a lock.

Objects backed by normal Perl containers retain their blessing so normal methods
continue to work.  GLOB/IO values are the same underlying open-file
description in every routine.  Opaque XS objects are the same object in
every routine too, because there is only one interpreter.

C<channel()> creates a process-wide channel object; it does not need C<share>.
With no argument it is unbuffered, matching an unbuffered Go channel: C<send> blocks
until a receiver accepts the value, and C<receive> blocks until a sender supplies
one. C<channel(N)> creates a buffered channel of capacity N: sends block only while
the buffer is full and receives block only while it is empty. Blocking is done by
pumping the engine, never by sleeping, so other routines keep running while a
sender or receiver waits. Values are plain Perl values passed by reference, so
nested Perl data and supported objects cross without copying. C<close> wakes blocked waiters; receiving from a
closed, drained channel returns undef in scalar context or C<(undef, 0)> in list
context, while a successful list-context receive returns C<($value, 1)>. Sending on
a closed channel throws an exception.

C<wait_all()> is the explicit barrier: call it whenever outstanding routines
must finish before the program continues or exits.  It pumps until no finite
routine is pending.  Repeating routines (a repeating timer, the accept loop)
are services, not tasks, and are not waited for.  At normal process exit an
END block drains outstanding finite routines first (repeating routines are
cancelled), with a 30 second bound, so a routine that was scheduled but never
waited for still runs before the process ends.  C<POSIX::_exit> skips the
drain, as before.

=head1 NATIVE PROCESSES

C<spawn(\@argv, \%options)> starts an independent operating-system process
through the Dashboard XS bundle. It accepts literal argument strings and
supports C<cwd>, C<env>, C<stdin>, C<stdout>, C<stderr>, and C<process_group>
options. The returned positive process id identifies the child independently
of the Perl interpreter. This API is separate from C<go>: a go routine runs a
Perl callback in a cloned interpreter, while C<spawn> starts a process that can
outlive its caller.

C<process_running($pid)> reports whether the process appears live.
C<process_exited($pid)> checks completion without reaping a POSIX child, which
allows a supervisor to poll safely before collecting its exit result.
C<wait_process($pid)> waits for and returns the shell-style exit status.
On Windows, waiting for a child that has already exited and been reaped
returns 255 because no exit code survives to report.
C<terminate_process($pid, $signal)> sends C<TERM>, C<KILL>, C<HUP>, or C<INT>
on POSIX. Windows supports C<TERM> and C<KILL>, mapped to native process
termination because POSIX signal handlers are unavailable there. Unsupported
signals, invalid identifiers and operating-system errors are reported as
exceptions; callers must not treat an inspection failure as a stopped process.

  my $pid = Developer::Dashboard::GoRoutine::spawn(
      [ $^X, '-e', 'sleep 1' ],
      { cwd => $workspace, process_group => 1 },
  );
  while (!Developer::Dashboard::GoRoutine::process_exited($pid)) {
      select undef, undef, undef, 0.02;
  }
  my $exit = Developer::Dashboard::GoRoutine::wait_process($pid);

=head1 EXAMPLES

Share a counter between a routine and the main program, then wait for the
routine to finish:

  use Developer::Dashboard::GoRoutine qw(go share wait_all);
  share my $count = 0;
  go sub { $count++ };
  wait_all();
  print "count=$count\n";

Start and collect a child process using literal arguments, without a shell:

  use Developer::Dashboard::GoRoutine qw(spawn wait_process);
  my $pid = spawn([ $^X, '-e', 'print "ready\\n"' ], {});
  my $exit = wait_process($pid);
  die "child failed with status $exit" if $exit != 0;

=cut
