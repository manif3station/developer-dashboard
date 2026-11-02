package Developer::Dashboard::GoRoutine;

use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(blessed reftype);
use Filter::Simple;

our $VERSION = '6.20';

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
# The XS function go(&) remains the primitive used for:
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

    if (tied($$slot)) {
        my $tied = tied($$slot);
        die "share() called on an already tied scalar"
            unless blessed($tied)
                && $tied->isa(__PACKAGE__ . '::SharedScalar');
    }
    else {
        my $initial = $$slot;
        tie $$slot, __PACKAGE__ . '::SharedScalar';
        $$slot = $initial;
    }

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
            my $tied = tied @$ref;
            if ($tied) {
                die "share() called on an already tied array"
                    unless blessed($tied)
                        && $tied->isa(__PACKAGE__ . '::SharedArray');
                next;
            }

            my @initial = @$ref;
            my $ptr = _shared_node_new();
            _shared_node_set($ptr, \@initial);
            tie @$ref, __PACKAGE__ . '::SharedArray', $ptr;
            next;
        }

        if ($type eq 'HASH') {
            my $tied = tied %$ref;
            if ($tied) {
                die "share() called on an already tied hash"
                    unless blessed($tied)
                        && $tied->isa(__PACKAGE__ . '::SharedHash');
                next;
            }

            my %initial = %$ref;
            my $ptr = _shared_node_new();
            _shared_node_set($ptr, \%initial);
            tie %$ref, __PACKAGE__ . '::SharedHash', $ptr;
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
    # closure and its captured argument list are then cloned by the XS go().
    return go(sub { $code->(@args) });
}

FILTER_ONLY code => sub {
    $_ = Developer::Dashboard::GoRoutine::_rewrite_user_syntax($_);
};

sub _proxy_ptr {
    my ($value) = @_;

    if (blessed($value)
        && $value->isa(__PACKAGE__ . '::SharedValue')) {
        return $value->{ptr};
    }

    return unless ref $value;

    my $type = reftype($value) || '';
    my $tied;

    if ($type eq 'HASH') {
        $tied = tied %{$value};
    }
    elsif ($type eq 'ARRAY') {
        $tied = tied @{$value};
    }
    elsif ($type eq 'SCALAR' || $type eq 'REF') {
        $tied = tied ${$value};
    }

    return unless blessed($tied)
        && $tied->isa(__PACKAGE__ . '::SharedProxyBase');

    return $tied->{ptr};
}

sub _value_for_ptr {
    my ($ptr) = @_;
    return undef unless $ptr;

    my $kind  = _shared_node_kind($ptr);
    my $class = _shared_node_class($ptr);

    if ($kind eq 'scalar') {
        return (__PACKAGE__ . '::SharedValue')->_new($ptr);
    }
    if ($kind eq 'hash') {
        return (__PACKAGE__ . '::SharedHash')->_new_ref($ptr, $class);
    }
    if ($kind eq 'array') {
        return (__PACKAGE__ . '::SharedArray')->_new_ref($ptr, $class);
    }
    if ($kind eq 'scalarref') {
        return (__PACKAGE__ . '::SharedScalarRef')->_new_ref($ptr, $class);
    }
    if ($kind eq 'object') {
        return _shared_object_proxy($ptr);
    }
    if ($kind eq 'code') {
        return sub { _shared_code_call($ptr, @_) };
    }
    if ($kind eq 'glob') {
        return _glob_for_ptr($ptr, $class);
    }
    if ($kind eq 'io') {
        return _io_for_ptr($ptr, $class);
    }
    if ($kind eq 'regexp') {
        return _regexp_for_ptr($ptr, $class);
    }
    if ($kind eq 'format') {
        return _format_for_ptr($ptr);
    }

    die "unknown shared value kind '$kind'";
}



# Materialize a real Perl filehandle/typeglob in the current interpreter.
# The C node owns a process-wide master descriptor.  Perl's three-argument
# >&/<& open duplicates that descriptor, so closing the fetched handle does
# not invalidate the shared node or handles fetched by other interpreters.
sub _open_shared_handle {
    my ($ptr) = @_;
    require Symbol;

    my $g = Symbol::gensym();
    my $fd = _shared_handle_fd($ptr);

    if ($fd >= 0) {
        my $mode = _shared_handle_mode($ptr);
        open($g, $mode, $fd)
            or die "cannot duplicate shared filehandle fd $fd: $!";
    }
    else {
        tie *{$g}, __PACKAGE__ . '::SharedHandle', $ptr;
    }

    return $g;
}

sub _glob_for_ptr {
    my ($ptr, $class) = @_;
    my $g = _open_shared_handle($ptr);

    if (my $p = _shared_glob_slot_ptr($ptr, 'scalar')) {
        *{$g} = _field_ref_for_ptr($p);
    }
    if (my $p = _shared_glob_slot_ptr($ptr, 'array')) {
        my $v = _value_for_ptr($p);
        *{$g} = $v;
    }
    if (my $p = _shared_glob_slot_ptr($ptr, 'hash')) {
        my $v = _value_for_ptr($p);
        *{$g} = $v;
    }
    if (my $p = _shared_glob_slot_ptr($ptr, 'code')) {
        my $v = _value_for_ptr($p);
        *{$g} = $v;
    }

    bless $g, $class if defined($class) && length($class);
    return $g;
}

sub _io_for_ptr {
    my ($ptr, $class) = @_;
    my $g = _open_shared_handle($ptr);
    my $io = *{$g}{IO};
    die "shared IO value has no materializable filehandle" unless $io;
    bless $io, $class if defined($class) && length($class);
    return $io;
}

sub _regexp_for_ptr {
    my ($ptr, $class) = @_;
    my $serialized = _shared_node_text($ptr);
    my $re = qr/$serialized/;
    bless $re, $class
        if defined($class) && length($class) && $class ne 'Regexp';
    return $re;
}

sub _format_for_ptr {
    my ($ptr) = @_;
    my $name = _shared_node_text($ptr);
    return undef unless defined($name) && length($name);
    no strict 'refs';
    return *{$name}{FORMAT};
}


# Runs inside the private handle interpreter for non-fd PerlIO handles.
sub _handle_remote_dispatch {
    my ($h, $op, @args) = @_;

    return print {$h} @args if $op eq 'PRINT';
    if ($op eq 'PRINTF') {
        my $format = shift @args;
        return printf {$h} $format, @args;
    }
    return scalar <$h> if $op eq 'READLINE_SCALAR';
    return <$h>        if $op eq 'READLINE_LIST';
    return getc($h)    if $op eq 'GETC';
    if ($op eq 'READ') {
        my ($length) = @args;
        my $buf = '';
        my $n = read($h, $buf, $length);
        return wantarray ? ($n, $buf) : $n;
    }
    if ($op eq 'WRITE') {
        my ($buf, $length, $offset) = @args;
        $offset //= 0;
        my $chunk = substr($buf, $offset, $length);
        my $ok = print {$h} $chunk;
        return $ok ? length($chunk) : undef;
    }
    return CORE::seek($h, $args[0], $args[1]) if $op eq 'SEEK';
    return tell($h)           if $op eq 'TELL';
    return eof($h)            if $op eq 'EOF';
    return fileno($h)         if $op eq 'FILENO';
    return @args ? CORE::binmode($h, $args[0]) : CORE::binmode($h) if $op eq 'BINMODE';
    return close($h)          if $op eq 'CLOSE';

    die "unsupported shared filehandle operation '$op'";
}

sub _scalar_snapshot {
    my ($value) = @_;
    if (blessed($value)
        && $value->isa(__PACKAGE__ . '::SharedValue')) {
        return _shared_scalar_get($value->{ptr});
    }
    return $value;
}

# Internal XS helper: create one tied field scalar for a shared class field.
sub _field_ref_for_ptr {
    my ($ptr) = @_;
    tie my $field, __PACKAGE__ . '::SharedScalar', $ptr;
    return \$field;
}

package Developer::Dashboard::GoRoutine::SharedHandle;

use strict;
use warnings;

sub TIEHANDLE {
    my ($class, $ptr) = @_;
    return bless { ptr => $ptr }, $class;
}

sub PRINT {
    my $self = shift;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'PRINT', @_
    );
}

sub PRINTF {
    my $self = shift;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'PRINTF', @_
    );
}

sub READLINE {
    my ($self) = @_;
    return wantarray
        ? Developer::Dashboard::GoRoutine::_shared_handle_remote(
            $self->{ptr}, 'READLINE_LIST'
          )
        : Developer::Dashboard::GoRoutine::_shared_handle_remote(
            $self->{ptr}, 'READLINE_SCALAR'
          );
}

sub GETC {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'GETC'
    );
}

sub READ {
    my ($self, undef, $length, $offset) = @_;
    $offset //= 0;
    my ($n, $chunk) = Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'READ', $length
    );
    return undef unless defined $n;
    my $buf = defined($_[1]) ? $_[1] : '';
    substr($buf, $offset, length($chunk), $chunk);
    $_[1] = $buf;
    return $n;
}

sub WRITE {
    my ($self, $buf, $length, $offset) = @_;
    $offset //= 0;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'WRITE', $buf, $length, $offset
    );
}

sub SEEK {
    my ($self, @args) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'SEEK', @args
    );
}

sub TELL {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'TELL'
    );
}

sub EOF {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'EOF'
    );
}

sub FILENO {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'FILENO'
    );
}

sub BINMODE {
    my ($self, @args) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'BINMODE', @args
    );
}

sub CLOSE {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_shared_handle_remote(
        $self->{ptr}, 'CLOSE'
    );
}

package Developer::Dashboard::GoRoutine::SharedProxyBase;

use strict;
use warnings;

sub _ptr { $_[0]{ptr} }

package Developer::Dashboard::GoRoutine::SharedScalar;

use strict;
use warnings;
use parent -norequire, 'Developer::Dashboard::GoRoutine::SharedProxyBase';
use Scalar::Util qw(blessed);

sub TIESCALAR {
    my ($class, $ptr) = @_;
    $ptr ||= Developer::Dashboard::GoRoutine::_shared_node_new();
    return bless { ptr => $ptr }, $class;
}

sub FETCH {
    return Developer::Dashboard::GoRoutine::_value_for_ptr($_[0]{ptr});
}

sub STORE {
    my ($self, $value) = @_;
    my $ptr = $self->{ptr};

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedOp')) {
        Developer::Dashboard::GoRoutine::_shared_scalar_apply(
            $value->{ptr},
            $value->{op},
            $value->{arg},
            $value->{reverse} ? 1 : 0,
        );
        return;
    }

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedValue')) {
        return if $value->{already_applied} && $value->{ptr} == $ptr;
        return if $value->{ptr} == $ptr;
        die "assigning one shared reference directly to another top-level shared scalar is not supported; assign it inside a shared hash/array instead";
    }

    my $proxy_ptr = Developer::Dashboard::GoRoutine::_proxy_ptr($value);
    if ($proxy_ptr) {
        die "assigning one shared reference directly to another top-level shared scalar is not supported; assign it inside a shared hash/array instead";
    }

    Developer::Dashboard::GoRoutine::_shared_node_set(
        $ptr, $value, utf8::is_utf8($value) ? 1 : 0
    );
}

package Developer::Dashboard::GoRoutine::SharedScalarRef;

use strict;
use warnings;

sub _new_ref {
    my ($class, $ptr, $bless_class) = @_;
    my $child = Developer::Dashboard::GoRoutine::_shared_scalarref_ptr($ptr);
    tie(my $slot, 'Developer::Dashboard::GoRoutine::SharedScalar', $child);
    my $ref = \$slot;
    bless $ref, $bless_class if defined($bless_class) && length($bless_class);
    return $ref;
}

package Developer::Dashboard::GoRoutine::SharedHash;

use strict;
use warnings;
use parent -norequire, 'Developer::Dashboard::GoRoutine::SharedProxyBase';
use Scalar::Util qw(blessed);

sub TIEHASH {
    my ($class, $ptr) = @_;
    return bless { ptr => $ptr, iter => [], iter_pos => 0 }, $class;
}

sub _new_ref {
    my ($class, $ptr, $bless_class) = @_;
    tie(my %hash, $class, $ptr);
    my $ref = \%hash;
    bless $ref, $bless_class if defined($bless_class) && length($bless_class);
    return $ref;
}

sub FETCH {
    my ($self, $key) = @_;
    my $ptr = Developer::Dashboard::GoRoutine::_shared_hash_fetch_ptr(
        $self->{ptr}, $key
    );
    return Developer::Dashboard::GoRoutine::_value_for_ptr($ptr);
}

sub STORE {
    my ($self, $key, $value) = @_;
    my $parent = $self->{ptr};

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedOp')) {
        Developer::Dashboard::GoRoutine::_shared_scalar_apply(
            $value->{ptr}, $value->{op}, $value->{arg},
            $value->{reverse} ? 1 : 0,
        );
        return;
    }

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedValue')) {
        return if $value->{already_applied};
        Developer::Dashboard::GoRoutine::_shared_hash_store_ptr(
            $parent, $key, $value->{ptr}
        );
        return;
    }

    my $proxy_ptr = Developer::Dashboard::GoRoutine::_proxy_ptr($value);
    if ($proxy_ptr) {
        Developer::Dashboard::GoRoutine::_shared_hash_store_ptr(
            $parent, $key, $proxy_ptr
        );
        return;
    }

    Developer::Dashboard::GoRoutine::_shared_hash_store(
        $parent, $key, $value
    );
}

sub EXISTS {
    return Developer::Dashboard::GoRoutine::_shared_hash_exists(
        $_[0]{ptr}, $_[1]
    );
}

sub DELETE {
    my ($self, $key) = @_;
    my $ptr = Developer::Dashboard::GoRoutine::_shared_hash_delete_ptr(
        $self->{ptr}, $key
    );
    return Developer::Dashboard::GoRoutine::_value_for_ptr($ptr);
}

sub CLEAR {
    Developer::Dashboard::GoRoutine::_shared_hash_clear($_[0]{ptr});
}

sub SCALAR {
    return 0 + Developer::Dashboard::GoRoutine::_shared_hash_count($_[0]{ptr});
}

sub FIRSTKEY {
    my ($self) = @_;
    $self->{iter} = [
        Developer::Dashboard::GoRoutine::_shared_hash_keys($self->{ptr})
    ];
    $self->{iter_pos} = 0;
    return $self->{iter}[ $self->{iter_pos}++ ];
}

sub NEXTKEY {
    my ($self) = @_;
    return undef if $self->{iter_pos} >= @{ $self->{iter} };
    return $self->{iter}[ $self->{iter_pos}++ ];
}

package Developer::Dashboard::GoRoutine::SharedArray;

use strict;
use warnings;
use parent -norequire, 'Developer::Dashboard::GoRoutine::SharedProxyBase';
use Scalar::Util qw(blessed);

sub TIEARRAY {
    my ($class, $ptr) = @_;
    return bless { ptr => $ptr }, $class;
}

sub _new_ref {
    my ($class, $ptr, $bless_class) = @_;
    tie(my @array, $class, $ptr);
    my $ref = \@array;
    bless $ref, $bless_class if defined($bless_class) && length($bless_class);
    return $ref;
}

sub FETCHSIZE {
    return 0 + Developer::Dashboard::GoRoutine::_shared_array_size($_[0]{ptr});
}

sub STORESIZE {
    Developer::Dashboard::GoRoutine::_shared_array_resize($_[0]{ptr}, $_[1]);
}

sub EXTEND { return }

sub FETCH {
    my ($self, $index) = @_;
    $index += $self->FETCHSIZE if $index < 0;
    my $ptr = Developer::Dashboard::GoRoutine::_shared_array_fetch_ptr(
        $self->{ptr}, $index
    );
    return Developer::Dashboard::GoRoutine::_value_for_ptr($ptr);
}

sub STORE {
    my ($self, $index, $value) = @_;
    my $size = $self->FETCHSIZE;
    $index += $size if $index < 0;

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedOp')) {
        Developer::Dashboard::GoRoutine::_shared_scalar_apply(
            $value->{ptr}, $value->{op}, $value->{arg},
            $value->{reverse} ? 1 : 0,
        );
        return;
    }

    if (blessed($value)
        && $value->isa('Developer::Dashboard::GoRoutine::SharedValue')) {
        return if $value->{already_applied};
        Developer::Dashboard::GoRoutine::_shared_array_store_ptr(
            $self->{ptr}, $index, $value->{ptr}
        );
        return;
    }

    my $proxy_ptr = Developer::Dashboard::GoRoutine::_proxy_ptr($value);
    if ($proxy_ptr) {
        Developer::Dashboard::GoRoutine::_shared_array_store_ptr(
            $self->{ptr}, $index, $proxy_ptr
        );
        return;
    }

    Developer::Dashboard::GoRoutine::_shared_array_store(
        $self->{ptr}, $index, $value
    );
}

sub EXISTS {
    my ($self, $index) = @_;
    $index += $self->FETCHSIZE if $index < 0;
    return Developer::Dashboard::GoRoutine::_shared_array_exists(
        $self->{ptr}, $index
    );
}

sub DELETE {
    my ($self, $index) = @_;
    $index += $self->FETCHSIZE if $index < 0;
    my $ptr = Developer::Dashboard::GoRoutine::_shared_array_delete_ptr(
        $self->{ptr}, $index
    );
    return Developer::Dashboard::GoRoutine::_value_for_ptr($ptr);
}

sub CLEAR {
    Developer::Dashboard::GoRoutine::_shared_array_clear($_[0]{ptr});
}

sub PUSH {
    my ($self, @values) = @_;
    for my $value (@values) {
        my $ptr = Developer::Dashboard::GoRoutine::_proxy_ptr($value);
        if ($ptr) {
            Developer::Dashboard::GoRoutine::_shared_array_push_ptr(
                $self->{ptr}, $ptr
            );
        }
        else {
            Developer::Dashboard::GoRoutine::_shared_array_push(
                $self->{ptr}, $value
            );
        }
    }
    return $self->FETCHSIZE;
}

sub UNSHIFT {
    my ($self, @values) = @_;
    for my $value (reverse @values) {
        my $ptr = Developer::Dashboard::GoRoutine::_proxy_ptr($value);
        if ($ptr) {
            Developer::Dashboard::GoRoutine::_shared_array_unshift_ptr(
                $self->{ptr}, $ptr
            );
        }
        else {
            Developer::Dashboard::GoRoutine::_shared_array_unshift(
                $self->{ptr}, $value
            );
        }
    }
    return $self->FETCHSIZE;
}

sub POP {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_value_for_ptr(
        Developer::Dashboard::GoRoutine::_shared_array_pop_ptr($self->{ptr})
    );
}

sub SHIFT {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_value_for_ptr(
        Developer::Dashboard::GoRoutine::_shared_array_shift_ptr($self->{ptr})
    );
}

sub SPLICE {
    my $self = shift;
    my $size = $self->FETCHSIZE;
    my $offset = @_ ? shift : 0;
    $offset += $size if $offset < 0;
    $offset = 0 if $offset < 0;
    $offset = $size if $offset > $size;
    my $length = @_ ? shift : $size - $offset;
    $length = $size - $offset + $length if $length < 0;
    $length = 0 if $length < 0;
    $length = $size - $offset if $length > $size - $offset;
    my @insert = @_;

    my @all = map { $self->FETCH($_) } 0 .. $size - 1;
    my @removed = splice @all, $offset, $length, @insert;
    $self->CLEAR;
    $self->PUSH(@all);

    return wantarray ? @removed : $removed[-1];
}

package Developer::Dashboard::GoRoutine::SharedValue;

use strict;
use warnings;

use overload
    '""'     => sub { "" . $_[0]->_value },
    '0+'     => sub { 0  + $_[0]->_value },
    'bool'   => sub { !! $_[0]->_value },

    '+'      => sub { $_[0]->_op('add',    $_[1], $_[2]) },
    '-'      => sub { $_[0]->_op('sub',    $_[1], $_[2]) },
    '*'      => sub { $_[0]->_op('mul',    $_[1], $_[2]) },
    '/'      => sub { $_[0]->_op('div',    $_[1], $_[2]) },
    '%'      => sub { $_[0]->_op('mod',    $_[1], $_[2]) },
    '.'      => sub { $_[0]->_op('concat', $_[1], $_[2]) },

    '++'     => sub {
        Developer::Dashboard::GoRoutine::_shared_scalar_apply(
            $_[0]{ptr}, 'inc', undef, 0
        );
        $_[0]{already_applied} = 1;
        $_[0];
    },
    '--'     => sub {
        Developer::Dashboard::GoRoutine::_shared_scalar_apply(
            $_[0]{ptr}, 'dec', undef, 0
        );
        $_[0]{already_applied} = 1;
        $_[0];
    },

    fallback => 1;

sub _new {
    my ($class, $ptr) = @_;
    return bless { ptr => $ptr }, $class;
}

sub _value {
    return Developer::Dashboard::GoRoutine::_shared_scalar_get($_[0]{ptr});
}

sub _op {
    my ($self, $op, $arg, $reverse) = @_;
    $arg = Developer::Dashboard::GoRoutine::_scalar_snapshot($arg);
    return bless {
        ptr     => $self->{ptr},
        op      => $op,
        arg     => $arg,
        reverse => $reverse ? 1 : 0,
    }, 'Developer::Dashboard::GoRoutine::SharedOp';
}

package Developer::Dashboard::GoRoutine::SharedOp;

use strict;
use warnings;

use overload
    '""'   => sub { "" . $_[0]->_evaluate },
    '0+'   => sub { 0  + $_[0]->_evaluate },
    'bool' => sub { !! $_[0]->_evaluate },
    fallback => 1;

sub _evaluate {
    my ($self) = @_;
    my $left  = Developer::Dashboard::GoRoutine::_shared_scalar_get($self->{ptr});
    my $right = $self->{arg};

    return $self->{reverse} ? $right + $left : $left + $right
        if $self->{op} eq 'add';
    return $self->{reverse} ? $right - $left : $left - $right
        if $self->{op} eq 'sub';
    return $self->{reverse} ? $right * $left : $left * $right
        if $self->{op} eq 'mul';
    return $self->{reverse} ? $right / $left : $left / $right
        if $self->{op} eq 'div';
    return $self->{reverse} ? $right % $left : $left % $right
        if $self->{op} eq 'mod';
    return $self->{reverse} ? $right . $left : $left . $right
        if $self->{op} eq 'concat';

    die "unknown shared operation '$self->{op}'";
}

package Developer::Dashboard::GoRoutine::Channel;

use strict;
use warnings;

sub _ptr {
    my ($self) = @_;
    die "invalid channel handle"
        unless ref($self) && exists $self->{ptr};
    return $self->{ptr};
}

sub send {
    my ($self, $value) = @_;
    Developer::Dashboard::GoRoutine::_channel_send($self->_ptr, $value);
    return $self;
}

sub receive {
    my ($self) = @_;
    return wantarray
        ? Developer::Dashboard::GoRoutine::_channel_receive($self->_ptr)
        : scalar Developer::Dashboard::GoRoutine::_channel_receive($self->_ptr);
}

sub close {
    my ($self) = @_;
    Developer::Dashboard::GoRoutine::_channel_close($self->_ptr);
    return $self;
}

sub is_closed {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_channel_is_closed($self->_ptr) ? 1 : 0;
}

sub size {
    my ($self) = @_;
    return 0 + Developer::Dashboard::GoRoutine::_channel_size($self->_ptr);
}

sub capacity {
    my ($self) = @_;
    return 0 + Developer::Dashboard::GoRoutine::_channel_capacity($self->_ptr);
}

package Developer::Dashboard::GoRoutine::Routine;

use strict;
use warnings;

sub _ptr {
    my ($self) = @_;
    die "invalid go routine handle"
        unless ref($self) && exists $self->{ptr};
    return $self->{ptr};
}

sub is_running {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_routine_is_running($self->_ptr) ? 1 : 0;
}

sub age {
    my ($self) = @_;
    return 0 + Developer::Dashboard::GoRoutine::_routine_age($self->_ptr);
}

sub kill {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_routine_kill($self->_ptr) ? 1 : 0;
}

sub timeout {
    my ($self, $seconds) = @_;
    die "timeout() requires a non-negative number of seconds"
        unless defined($seconds)
            && $seconds =~ /\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
            && 0 + $seconds == 0 + $seconds
            && abs(0 + $seconds) < 1e308;

    Developer::Dashboard::GoRoutine::_routine_timeout($self->_ptr, 0 + $seconds);
    return $self;
}

sub status {
    my ($self) = @_;
    return Developer::Dashboard::GoRoutine::_routine_status($self->_ptr);
}

sub is_killed {
    my ($self) = @_;
    my $status = $self->status;
    return ($status eq 'killed' || $status eq 'timed_out') ? 1 : 0;
}

package Developer::Dashboard::GoRoutine;

1;

__END__

=head1 NAME

Developer::Dashboard::GoRoutine - go-style native threads with transparent shared Perl data

=head1 PURPOSE

This module provides the Developer Dashboard concurrency API: cloned Perl
goroutines, synchronized shared Perl values, channels, and native operating
system process management. It keeps those facilities under the existing
C<Developer::Dashboard::*> namespace while loading their implementation from
the distribution's XS bundle.

=head1 WHY IT EXISTS

Dashboard collectors, services, and tools need concurrent work and managed
subprocesses across supported operating systems. Perl's direct C<fork()> is
not portable to Windows and does not provide shared Perl references between
workers. This module supplies explicit APIs for both in-process routines and
independent child processes, with errors surfaced to the caller.

=head1 WHEN TO USE

Use C<go> for a Perl callback that should run concurrently, C<share> or
C<channel> when workers need to exchange supported values, and C<spawn> when
an independent operating-system process is required. Use C<wait_all> before
program exit whenever outstanding routines must finish. Choose C<spawn>
instead of C<go> when the work must run as a separate process rather than in a
cloned interpreter.

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

C<go> executes a cloned Perl interpreter on a detached POSIX pthread and returns
a routine handle.  It does not call C<fork()> and does not require the caller
to use Perl's C<threads> module.  The handle provides C<age>, C<is_running>,
C<kill>, C<timeout>, and C<status>.

Cancellation is cooperative and checked at Perl execution boundaries.  The
module also sends an internal wake signal to interrupt ordinary blocking waits
such as C<sleep> so a killed or timed-out routine can unwind promptly.  An
opaque XS/C call that never returns cannot be forcibly torn down safely.

Inside a go routine, Perl C<exit> is scoped to that routine: it unwinds the
worker instead of terminating the whole process.  C<exit> in the main
interpreter keeps normal Perl semantics.

C<share my $x = VALUE> creates one process-wide C-backed value that is visible
to the main interpreter and every cloned interpreter.  Scalars, hashes, arrays, nested combinations, scalar/reference chains, CODE,
GLOB/filehandles, IO references, regular expressions, formats, lvalue/version
scalar references, Perl 5.40 field objects, and ordinary blessed data-backed
objects are supported. Normal Perl dereferencing and filehandle syntax is retained.

Scalar read/modify/write operations such as C<++>, C<-->, C<+=>, C<-=>,
C<*=>, C</=>, C<%=> and C<.=> are applied while the native shared lock is held.
Hash and array structural operations are also synchronized by the module.

Objects backed by normal Perl containers retain their blessing so normal methods
continue to work. CODE references use a private callback interpreter. GLOB/IO
values backed by an OS descriptor are materialized as real handles in each Perl
interpreter while referring to the same underlying open-file description. Opaque
XS objects whose semantics live entirely in module-private native pointers cannot
be made generically shared by Perl itself; those remain subject to the XS module's
own thread/cloning rules.

C<channel()> creates a process-wide channel object; it does not need C<share>.
With no argument it is unbuffered, matching an unbuffered Go channel: C<send> blocks
until a receiver accepts the value, and C<receive> blocks until a sender supplies
one. C<channel(N)> creates a buffered channel of capacity N: sends block only while
the buffer is full and receives block only while it is empty. Values use the same
shared-value marshalling layer as C<share>, so nested Perl data and supported objects
can cross interpreter boundaries. C<close> wakes blocked waiters; receiving from a
closed, drained channel returns undef in scalar context or C<(undef, 0)> in list
context, while a successful list-context receive returns C<($value, 1)>. Sending on
a closed channel throws an exception.

Go routines are not waited for automatically at Perl shutdown.  C<wait_all()> is
the explicit barrier: call it whenever outstanding routines must finish before the
program continues or exits.  Without C<wait_all()>, normal process termination may
end still-running routines.

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

Share a counter between a worker and the main interpreter, then wait for the
worker to finish:

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
