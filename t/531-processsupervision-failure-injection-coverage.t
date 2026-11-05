#!/usr/bin/env perl

use strict;
use warnings;

# BEGIN-time CORE::GLOBAL::open override: it fails or redirects only for exact
# registered paths, so these branches run the same for root and non-root users.
our ( %OPEN_FAIL, %OPEN_REDIRECT, %READ_DUP_FAIL, $FORCE_DEV_FD_LINK );

BEGIN {
    *CORE::GLOBAL::open = sub (*;$@) {
        # Force the first descriptor duplication to fail so the writable
        # fallback branch is exercised on both Unix and Windows.
        if ( @_ >= 3 && defined $_[1] && $_[1] eq '<&'
             && defined $_[2] && $READ_DUP_FAIL{$_[2]} ) {
            $! = 9;
            return 0;
        }
        if ( @_ >= 3 && defined $_[2] && !ref $_[2] ) {
            my $path = $_[2];
            if ( $OPEN_FAIL{$path} ) {
                $! = 13;
                return 0;
            }
            if ( my $redirect = $OPEN_REDIRECT{$path} ) {
                return CORE::open( $_[0], $redirect->[0], @{$redirect}[ 1 .. $#{$redirect} ] );
            }
        }
        return CORE::open( $_[0], $_[1] ) if @_ == 2;
        return CORE::open( $_[0], $_[1], @_[ 2 .. $#_ ] );
    };

    *CORE::GLOBAL::readlink = sub (_) {
        return undef if $FORCE_DEV_FD_LINK && $_[0] =~ m{\A/proc/self/fd/};
        return 'anon_inode:[eventfd]'
            if $FORCE_DEV_FD_LINK && $_[0] =~ m{\A/dev/fd/};
        return CORE::readlink($_[0]);
    };
}

use Test::More;
use Capture::Tiny qw(capture);
use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';

use Developer::Dashboard::ProcessSupervision;

my $dir  = tempdir( CLEANUP => 1 );
my $self = bless {}, 'Developer::Dashboard::ProcessSupervision';

# In-place overwrite on Windows: the source pending file is consumed.
{
    no warnings 'redefine';
    local *Developer::Dashboard::ProcessSupervision::is_windows = sub { 1 };
    my $source = File::Spec->catfile( $dir, 'source.tmp' );
    my $target = File::Spec->catfile( $dir, 'target.json' );
    open my $fh, '>', $source or die $!;
    print {$fh} "payload";
    close $fh;
    my ( $ok, $err ) = $self->_overwrite_state_file_in_place( $source, $target );
    ok( $ok, 'in-place overwrite succeeds' );
    ok( !-e $source, 'the pending source file is removed after the overwrite' );
    ( $ok, $err ) = Developer::Dashboard::ProcessSupervision::_overwrite_state_file_in_place( $self, $source, $target );
    ok( !$ok, 'a missing source is reported as a failure' );
}

# Descriptor listing yields numeric descriptors only.
{
    my @fds = $self->_open_file_descriptors;
    ok( scalar( grep { $_ == 0 } @fds ), 'descriptor listing includes stdin' );
    ok( !scalar( grep { $_ !~ /^\d+$/ } @fds ), 'descriptor listing is numeric only' );
}

# Child-library path filtering uses the current working directory when the
# captured base is empty and rejects non-path @INC hooks and empty entries.
{
    local $Developer::Dashboard::ProcessSupervision::PERL_LIBRARY_BASE = '';
    local @INC = ( undef, [], '', 'relative-lib' );
    is_deeply(
        [ $self->_perl_library_args ],
        [ '-I' . File::Spec->rel2abs('relative-lib') ],
        '_perl_library_args resolves relative paths from cwd and omits non-path @INC entries',
    );
}

{
    no warnings 'redefine';
    local $Developer::Dashboard::ProcessSupervision::PERL_LIBRARY_BASE = '';
    local @INC = ('relative-lib');
    local *Developer::Dashboard::ProcessSupervision::getcwd = sub { return undef };
    is_deeply(
        [ $self->_perl_library_args ],
        [ '-I' . File::Spec->rel2abs('relative-lib') ],
        '_perl_library_args remains usable when getcwd cannot provide a fallback base',
    );
}

# Descriptor cleanup must leave non-pipe descriptors alone and close selected
# inherited-pipe descriptors. The close call is stubbed so this unit test never
# changes the test process' own descriptor table.
{
    no warnings 'redefine';
    my @closed;
    local *Developer::Dashboard::ProcessSupervision::_open_file_descriptors = sub { return ( 42, 43 ) };
    local *Developer::Dashboard::ProcessSupervision::_descriptor_is_inherited_pipe = sub {
        return $_[1] == 43;
    };
    local *POSIX::close = sub { push @closed, $_[0]; return 1 };
    is( $self->_close_inherited_fds, 1, '_close_inherited_fds completes after checking inherited descriptors' );
    is_deeply( \@closed, [43], 'cleanup skips non-pipes and closes only inherited pipe descriptors' );
}

# Cover the descriptor fallbacks without changing real process descriptors.
# The write-only file is never a pipe or socket, and can be closed normally.
{
    my $regular = File::Spec->catfile( $dir, 'descriptor-fallback' );
    open my $regular_fh, '>', $regular or die "Unable to open $regular: $!";
    my $fd = fileno($regular_fh);
    ok( defined $fd, 'the descriptor fallback fixture has a file number' );

    {
        local $READ_DUP_FAIL{$fd} = 1;
        is(
            $self->_descriptor_is_inherited_pipe( $fd, close_ipc => 1 ),
            0,
            'a failed read duplication falls back to a writable descriptor',
        );
    }

    {
        local $FORCE_DEV_FD_LINK = 1;
        is(
            Developer::Dashboard::ProcessSupervision::_fd_link_target($fd),
            'anon_inode:[eventfd]',
            'the descriptor link falls back to devfs when procfs is unavailable',
        );
        is(
            $self->_descriptor_is_inherited_pipe( $fd, close_ipc => 1 ),
            1,
            'an anonymous kernel descriptor is recognised through the fallback',
        );
    }

    {
        no warnings 'redefine';
        local *Developer::Dashboard::ProcessSupervision::_fd_link_target = sub {
            return undef;
        };
        is(
            $self->_descriptor_is_inherited_pipe( $fd, close_ipc => 1 ),
            0,
            'a descriptor without any link target is not an inherited pipe',
        );
    }

    close $regular_fh or die "Unable to close $regular: $!";
}

# Inherited-pipe detection for an unknown descriptor.
is( $self->_descriptor_is_inherited_pipe(99999), 0, 'a closed descriptor is not an inherited pipe' );

# Process environment marker reads.
{
    my $envfile = File::Spec->catfile( $dir, 'environ' );
    open my $fh, '>', $envfile or die $!;
    print {$fh} "A=1\0DD_MARK=found\0";
    close $fh;

    my $real = $$;
    my $real_proc = "/proc/$real/environ";

    {
        local $OPEN_REDIRECT{$real_proc} = [ '<', $envfile ];
        SKIP: {
            skip 'procfs permission precondition unavailable', 1 if !-r $real_proc;
            is( $self->_read_process_env_marker( $real, 'DD_MARK' ), 'found',
                'the marker is read from the process environment' );
        }
        is( $self->_read_process_env_marker( $real, 'MISSING' ), undef, 'an absent marker reads as undef' );
    }
    {
        local $OPEN_FAIL{$real_proc} = 1;
        is( $self->_read_process_env_marker( $real, 'DD_MARK' ), undef, 'an unopenable environ file reads as undef' );
    }
    {
        my $empty = File::Spec->catfile( $dir, 'empty-environ' );
        open my $efh, '>', $empty or die $!;
        close $efh;
        local $OPEN_REDIRECT{$real_proc} = [ '<', $empty ];
        is( $self->_read_process_env_marker( $real, 'DD_MARK' ), undef, 'an empty environ reads as undef' );
    }
    {
        local $OPEN_REDIRECT{$real_proc} = [ '<', $dir ];
        my $marker;
        my ( $stdout, $stderr, $exit ) = capture {
            $marker = $self->_read_process_env_marker( $real, 'DD_MARK' );
        };
        is( $marker, undef, 'an unreadable environ slurp reads as undef' );
        is( $stdout, '', 'an unreadable environ slurp emits no standard output' );
        is( $stderr, '', 'an unreadable environ slurp emits no warning' );
    }
}

# Read procfs metadata from a private directory so macOS and Windows also
# execute the real parser instead of skipping Linux-only /proc entries.
{
    require File::Path;
    my $root = File::Spec->catdir( $dir, 'portable-proc' );
    my $pid = 61234;
    my $pid_dir = File::Spec->catdir( $root, $pid );
    File::Path::make_path($pid_dir);
    my $environ = File::Spec->catfile( $pid_dir, 'environ' );
    open my $fh, '>:raw', $environ or die "Unable to create $environ: $!";
    print {$fh} "NOT_AN_ENV_ENTRY\0DD_MARK=fixture\0";
    close $fh or die "Unable to close $environ: $!";
    local $Developer::Dashboard::ProcessSupervision::PROCFS_ROOT = $root;
    is( $self->_read_process_env_marker( $pid, 'DD_MARK' ), 'fixture',
        '_read_process_env_marker parses real binary NUL-delimited fixture data' );
    is( $self->_read_process_env_marker( $pid, 'ABSENT' ), undef,
        '_read_process_env_marker returns undef for a missing key in readable procfs data' );
    is( $self->_read_process_env_marker( $pid + 1, 'DD_MARK' ), undef,
        '_read_process_env_marker handles a missing procfs entry on every platform' );
    {
        local $OPEN_FAIL{$environ} = 1;
        is( $self->_read_process_env_marker( $pid, 'DD_MARK' ), undef,
            '_read_process_env_marker handles a denied open after the readable-file check' );
    }
    my $ns_dir = File::Spec->catdir( $pid_dir, 'ns' );
    File::Path::make_path($ns_dir);
    my $namespace = File::Spec->catfile( $ns_dir, 'pid' );
    is( $self->_pid_namespace_id($pid), undef,
        '_pid_namespace_id ignores a missing namespace link' );
    SKIP: {
        skip 'symlinks unavailable on this host', 1 if !symlink( 'pid:[fixture]', $namespace );
        is( $self->_pid_namespace_id($pid), 'pid:[fixture]',
            '_pid_namespace_id reads a valid procfs namespace link' );
    }
}

# Helper file support: a read handle whose close reports failure.
{
    my $helper = File::Spec->catfile( $dir, 'helper.pl' );
    open my $fh, '>', $helper or die $!;
    print {$fh} "web-foreground\n";
    close $fh;
    local $OPEN_REDIRECT{$helper} = [ '-|', 'sh', '-c', 'echo web-foreground; exit 3' ];
    is( $self->_helper_file_supports_internal_command( $helper, 'web-foreground' ), 0, 'a helper whose handle fails to close is not supported' );
}

done_testing;

__END__

=pod

=head1 NAME

t/531-processsupervision-failure-injection-coverage.t - failure-injection coverage for Developer::Dashboard::ProcessSupervision

=head1 PURPOSE

This regression test covers ProcessSupervision's in-place overwrite cleanup,
descriptor enumeration, fallback duplication and link-target handling,
child Perl library-path construction,
process-environment reads, and helper-file close failures. A BEGIN-time
C<CORE::GLOBAL::open> override fails or redirects only exact registered paths,
so failure branches are testable without depending on filesystem permissions
that behave differently under root.

=head1 WHY IT EXISTS

It exists because the lib/ coverage gate requires every branch to be genuinely executed with no uncoverable annotations, and chmod-based failures do not work when the suite runs as root.

=head1 WHEN TO USE

Use this file when you change the state-file overwrite, descriptor inspection, process environment marker reader or helper-support check in ProcessSupervision.

=head1 HOW TO USE

Run it directly with C<prove -lv t/531-processsupervision-failure-injection-coverage.t>. Redirect entries substitute the arguments of the real open, so a pipe open whose close fails can stand in for a read handle.

=head1 WHAT USES IT

It is used by developers during TDD, by the full C<prove -lr t> suite, by the Devel::Cover coverage gate, and by release verification.

=head1 EXAMPLES

Example 1:

  prove -lv t/531-processsupervision-failure-injection-coverage.t

Run these tests by themselves while editing ProcessSupervision.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/531-processsupervision-failure-injection-coverage.t

Confirm the injected branches are reported as covered.

=cut
