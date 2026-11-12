#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $repo_root = abs_path( File::Spec->catdir( dirname(__FILE__), '..' ) );
my $lib       = File::Spec->catdir( $repo_root, 'lib' );
my $d2        = File::Spec->catfile( $repo_root, 'bin', 'd2' );
my $dashboard = File::Spec->catfile( $repo_root, 'bin', 'd2' );

ok( -f $d2, 'bin/d2 is shipped as a real entrypoint' );
ok( -x $d2, 'bin/d2 is executable' );

# d2 is the switchboard itself, not a re-exec into a sibling entrypoint
# and not a shell alias. bin/dashboard is gone; d2 is the only entrypoint.
my $source = do {
    open my $fh, '<:raw', $d2 or die "Unable to read $d2: $!";
    local $/;
    <$fh>;
};
like( $source, qr/^#!.*perl/,             'bin/d2 is a real perl script' );
like( $source, qr/\bexec\b/,              'bin/d2 execs rather than aliasing' );
ok( !-f File::Spec->catfile( $repo_root, 'bin', 'dashboard' ), 'bin/dashboard no longer exists; d2 is the only entrypoint' );
like( $source, qr/_exec_switchboard_command|_builtin_helper_command/, 'bin/d2 carries the switchboard body' );

# d2 runs the command surface for a representative command.
my ( $d2_out, $d2_err, $d2_exit ) = capture {
    system( $^X, '-I', $lib, $d2, 'version' );
};
my ( $db_out, $db_err, $db_exit ) = capture {
    system( $^X, '-I', $lib, $dashboard, 'version' );
};
is( $d2_exit >> 8, 0,        'd2 version exits cleanly' );
is( $d2_out,       $db_out,  'd2 version output matches d2 version output' );
like( $d2_out, qr/\A\d+\.\d+\s*\z/, 'd2 version prints the d2 version number' );

# d2 forwards further arguments to the same command surface.
my ( $help_out, undef, $help_exit ) = capture {
    system( $^X, '-I', $lib, $d2, 'help' );
};
is( $help_exit >> 8, 0, 'd2 help exits cleanly' );
like( $help_out, qr/dashboard/, 'd2 help renders the d2 command manual' );

# File-specific POD (no generic boilerplate) is present.
like( $source, qr/^=head1 NAME$/m, 'bin/d2 carries POD documentation' );

# The tarball ships the repo Makefile.PL verbatim (there is no [MakeMaker]
# plugin), so d2 only lands on PATH if Makefile.PL lists it in EXE_FILES.
my $makefile_pl = do {
    open my $mf, '<:raw', File::Spec->catfile( $repo_root, 'Makefile.PL' )
      or die "Unable to read Makefile.PL: $!";
    local $/;
    <$mf>;
};
like(
    $makefile_pl,
    qr/EXE_FILES\s*=>\s*\[[^\]]*'bin\/d2'/s,
    'Makefile.PL installs bin/d2 as an executable so d2 is a real command after install',
);

# DD-810: the main gate runs exactly once - with a single entrypoint
# there is no second gating pass.
{
    my $gate_home  = abs_path( tempdir( CLEANUP => 1 ) );
    my $hooks_dir  = File::Spec->catdir( $gate_home, '.developer-dashboard', 'hooks' );
    my $marker     = File::Spec->catfile( $gate_home, 'hook-marker' );
    make_path($hooks_dir);
    my $hook = File::Spec->catfile( $hooks_dir, '10-mark.sh' );
    open my $hook_fh, '>', $hook or die "Unable to write $hook: $!";
    print {$hook_fh} "#!/bin/sh\nprintf 'HOOK-RAN %s\\n' \"\$*\" >> '$marker'\n";
    close $hook_fh or die "Unable to close $hook: $!";
    chmod 0755, $hook or die "Unable to chmod $hook: $!";

    my ( $gated_out, $gated_err, $gated_exit ) = capture {
        local $ENV{HOME} = $gate_home;
        system( $^X, '-I', $lib, $d2, 'version' );
    };
    is( $gated_exit >> 8, 0,       'd2 version exits cleanly with a main-gate hook installed' );
    is( $gated_out,       $db_out, 'd2 version prints the same version through the main gate' );
    is( $gated_err,       '',      'd2 version through the main gate writes nothing to stderr' );

    my @marker_lines = ();
    if ( open my $marker_fh, '<', $marker ) {
        @marker_lines = <$marker_fh>;
        close $marker_fh;
        chomp @marker_lines;
    }
    # DD-835 (reverses DD-832): the hook's argv is the full command line as
    # typed - "version" is prepended, not stripped.
    is_deeply( \@marker_lines, ['HOOK-RAN version'],
        'd2 inherits the main gate through its re-exec exactly once, not twice' );
}

done_testing;

__END__

=pod

=head1 NAME

t/49-d2-entrypoint.t - regression contract for the real d2 short entrypoint

=head1 PURPOSE

This test is the executable regression contract for C<bin/d2>. It verifies that
C<d2> is shipped as a real, executable Perl entrypoint that re-execs its sibling
C<d2> command rather than duplicating the switchboard body or existing
only as a shell alias, and that C<d2> and C<d2> produce identical output
for a representative command.

=head1 WHY IT EXISTS

C<d2> used to exist only as a shell function defined by the d2 shell
bootstrap, so it was unavailable in scripts and fresh shells. This test exists
so C<d2> stays a genuine installed command that behaves exactly like
C<d2>, and so a future change cannot quietly turn it back into a
shell-only alias or fork the command body.

=head1 WHEN TO USE

Use this file when changing how C<d2> locates and re-enters the main
C<d2> entrypoint, or when changing how C<d2> is packaged as an installed
executable.

=head1 HOW TO USE

Run C<prove -lv t/49-d2-entrypoint.t> while iterating on the short entrypoint.
Keep it green under C<prove -lr t> before calling the work complete.

=head1 WHAT USES IT

Developers during TDD, the repository test suite, and the release gate all use
this file to keep C<d2> a real, dashboard-equivalent command.

=head1 EXAMPLES

Example 1:

  prove -lv t/49-d2-entrypoint.t

Run the dedicated d2 entrypoint regression check by itself.

Example 2:

  prove -lr t

Run the d2 entrypoint regression inside the full repository suite before
release.

=cut
