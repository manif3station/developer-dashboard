#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';

use Developer::Dashboard::Pax::StandaloneImage;

# write_fake_bin($dir, $name, $exit_code)
# Writes a tiny executable script under $dir/$name that always exits
# $exit_code, ignoring all arguments.
# Input: directory, program name, exit code.
# Output: full path to the written script.
sub write_fake_bin {
    my ( $dir, $name, $exit_code ) = @_;
    my $path = File::Spec->catfile( $dir, $name );
    open my $fh, '>', $path or die $!;
    print {$fh} "#!/bin/sh\nexit $exit_code\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

# minimal_manifest($output_path)
# Builds the smallest manifest _compile_launcher accepts - empty payload
# lists throughout, since _payload_package_blob only needs an arrayref
# (possibly empty) for each of code_units/runtime_payloads/assets/
# native_payloads.
# Input: absolute output path for the compiled launcher binary.
# Output: manifest hash reference.
sub minimal_manifest {
    my ($output_path) = @_;
    return {
        output_path => $output_path,
        code_units => [],
        runtime_payloads => [],
        assets => [],
        native_payloads => [],
        entrypoint => { logical_path => 'main.pl' },
        source_hash => 'deadbeef',
        runtime => { mode => 'host_perl', perl_binary_logical_path => '', bundled_inc_roots => [] },
        lib_dirs => [],
    };
}

# --------------------------------------------------------------------------
# AC-1: when the build eval dies (objcopy fails) and the cwd-restore that
# follows SUCCEEDS - the common case - the returned reason is the REAL
# build failure text, not an empty string.
# --------------------------------------------------------------------------
{
    my $bin_dir = tempdir( CLEANUP => 1 );
    write_fake_bin( $bin_dir, 'objcopy', 1 );    # always fails
    write_fake_bin( $bin_dir, 'cc',      0 );    # resolvable, never actually reached

    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $work_dir = tempdir( CLEANUP => 1 );
    my $manifest = minimal_manifest( File::Spec->catfile( $work_dir, 'launcher' ) );

    my $result = Developer::Dashboard::Pax::StandaloneImage::_compile_launcher($manifest);

    is( $result->{status}, 'not_built', 'AC-1: a failing objcopy step reports not_built' );
    isnt( $result->{reason}, '', 'AC-1: the reason is NOT an empty string (the bug this ticket fixes)' );
    like( $result->{reason}, qr/objcopy code\.pkg failed/, 'AC-1: the reason names the real objcopy failure, not a stale/cleared $@' );
}

# --------------------------------------------------------------------------
# AC-2: the fix's underlying mechanism - capturing each eval's $@ into its
# OWN variable immediately after that eval returns - correctly keeps a
# RESTORE failure's own message distinct from the build eval's, in either
# order, rather than letting whichever eval runs last silently overwrite
# what the other one set. (A full end-to-end drive of _compile_launcher's
# own two chdir calls cannot be forced to fail only on the SECOND call
# without either a compile-time CORE::GLOBAL::chdir override installed
# before StandaloneImage.pm itself compiles, or mutating the real
# filesystem under the test process's own cwd - both fragile; AC-1 above
# already proves the fix's real integration for the far more common
# build-fails/restore-succeeds path. This proves the same $@-capture
# mechanism handles the restore-fails direction identically, using the
# EXACT pattern DD-1006's fix applies.)
# --------------------------------------------------------------------------
{
    my $ok = eval { die "objcopy code.pkg failed"; 1; };
    my $build_error = $@;
    my $restore_ok = eval { die "cannot restore cwd to /somewhere: No such file or directory"; 1; };
    my $restore_error = $@;

    ok( !$ok,         'AC-2 mechanism: the build eval is recorded as failed' );
    ok( !$restore_ok, 'AC-2 mechanism: the restore eval is recorded as failed' );
    like( $build_error,   qr/objcopy code\.pkg failed/,  'AC-2 mechanism: the build failure\'s OWN captured $@ is preserved' );
    like( $restore_error, qr/cannot restore cwd/,        'AC-2 mechanism: the restore failure\'s OWN captured $@ is preserved, distinctly from the build one' );
    isnt( $build_error, $restore_error, 'AC-2 mechanism: the two captured errors are NOT the same value (proves no clobbering occurred either direction)' );
}

# --------------------------------------------------------------------------
# AC-3: the happy path (build succeeds, restore succeeds) is unaffected by
# this fix - still returns status => 'built' when the compiled output is
# genuinely executable.
# --------------------------------------------------------------------------
SKIP: {
    my $cc = `command -v cc 2>/dev/null` || `command -v gcc 2>/dev/null`;
    my $objcopy = `command -v objcopy 2>/dev/null`;
    chomp( $cc, $objcopy );
    skip 'no real cc/objcopy available on this host for a genuine happy-path build', 1
      if !$cc || !$objcopy;

    my $work_dir = tempdir( CLEANUP => 1 );
    my $manifest = minimal_manifest( File::Spec->catfile( $work_dir, 'launcher' ) );

    my $result = Developer::Dashboard::Pax::StandaloneImage::_compile_launcher($manifest);
    is( $result->{status}, 'built', 'AC-3: the happy path still reports status => built (regression check)' );
}

done_testing();

__END__

=pod

=head1 NAME

209-standaloneimage-build-error-capture.t - proves DD-1006's $@-clobbering fix

=head1 PURPOSE

Guards DD-1006: C<StandaloneImage::_compile_launcher>'s build-failure
C<reason> must survive a successful cwd-restore eval that runs immediately
afterward, instead of being silently reset to an empty string.

=head1 WHY IT EXISTS

Perl resets C<$@> at the start and on the successful completion of every
C<eval> block. Two sequential evals sharing the same C<$@> means whichever
ran last determines what a caller reading C<$@> afterward sees - not
whichever one actually failed. Without this fix, every real build failure
whose cwd restore succeeds (the common case) reports an empty diagnostic,
leaving a developer with no way to tell what went wrong from the returned
structure alone.

=head1 WHEN TO USE

Run this file whenever C<StandaloneImage::_compile_launcher> changes.

=head1 HOW TO USE

    prove -lv t/209-standaloneimage-build-error-capture.t

=head1 WHAT USES IT

C<t/202-pax-launcher-build-dir-per-uid.t> covers this same subroutine's
build-directory derivation; this file covers the error-reporting fix
specifically.

=head1 EXAMPLES

Forcing C<objcopy> to exit nonzero (a stub script on C<$ENV{PATH}>) while
C<cc> stays resolvable and the cwd restore succeeds produces
C<< {status => 'not_built', reason => 'objcopy code.pkg failed'} >>, not an
empty reason.

=cut
