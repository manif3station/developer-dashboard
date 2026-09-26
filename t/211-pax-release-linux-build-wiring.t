#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use YAML::XS qw(LoadFile);

plan skip_all => 'checkout-only workflow validation; release tarballs exclude .github'
    if !-f '.github/workflows/pax-release.yml';

my $path = '.github/workflows/pax-release.yml';
my $raw = do { local $/; open my $fh, '<', $path or die "cannot read $path: $!"; <$fh> };
my $workflow = LoadFile($path);

my $job = ( values %{ $workflow->{jobs} } )[0];
my @steps = @{ $job->{steps} };
my %step_by_name = map { $_->{name} => $_ } @steps;

# AC-2/AC-3: a real pax build step exists for Linux, gated correctly.
my $build_step = $step_by_name{'PAX build dashboard (Linux only)'};
ok( $build_step, 'a real "PAX build dashboard" step exists' );
is( $build_step->{if}, q{startsWith(matrix.target, 'linux-')}, 'the build step is gated to Linux targets only' );
like( $build_step->{run}, qr/pax build --compact -o pax-output\/d2 bin\/dashboard/, 'the build step invokes pax build against bin/dashboard, no paxfile - output named d2 (DD-1015/DD-1025)' );

# the last still-unimplemented target (windows-arm64) keeps its own
# placeholder - windows-amd64 (DD-1015) and macOS (DD-1014) both got
# real build steps, so neither is part of this placeholder anymore.
my $placeholder_step = $step_by_name{'PAX build (placeholder, windows-arm64 only)'};
ok( $placeholder_step, 'the windows-arm64 placeholder step still exists' );
is( $placeholder_step->{if}, q{matrix.target == 'windows-arm64'}, 'the placeholder step is gated to windows-arm64 only' );

# AC-5 (DD-1014): a real macOS build step exists, output named d2.
my $macos_build_step = $step_by_name{'PAX build dashboard (macOS only)'};
ok( $macos_build_step, 'a real "PAX build dashboard (macOS only)" step exists' );
is( $macos_build_step->{if}, q{matrix.target == 'macos-arm64'}, 'the macOS build step is gated to macos-arm64 only' );
like( $macos_build_step->{run}, qr/pax build --compact -o pax-output\/d2 bin\/dashboard/, 'the macOS build step invokes pax build, output named d2' );

# AC-3: the i686 toolchain step, and specifically the self-recursion fix.
my $i686_step = $step_by_name{'Install 32-bit toolchain (linux-i686 only)'};
ok( $i686_step, 'the i686 toolchain-install step exists' );
is( $i686_step->{if}, q{matrix.target == 'linux-i686'}, 'the i686 step is gated to linux-i686 only' );
like( $i686_step->{run}, qr/gcc-multilib/, 'installs gcc-multilib' );
like( $i686_step->{run}, qr/command -v cc/, 'resolves the real cc via command -v before building the wrapper (not a bare name)' );
like( $i686_step->{run}, qr/exec %s -m32/, 'the wrapper script template execs the resolved absolute path with -m32' )
    or diag('DD-1013: the wrapper MUST exec an absolute cc path, never the bare name "cc" - a wrapper that execs "cc" ' .
            'resolves through the same PATH it was just prepended to and calls ITSELF, recursing forever. ' .
            'Caught live: an 18+ minute runaway at 96% CPU with zero output before this was fixed.');
unlike( $i686_step->{run}, qr/exec cc -m32/, 'the wrapper does NOT exec the bare name "cc" (the self-recursion bug this ticket caught and fixed)' );

# AC-1 (unchanged from DD-1012, step later widened to also cover Windows -
# DD-1015): dependency install for Linux (and now Windows amd64) jobs.
my $deps_step = $step_by_name{'Install Perl dependencies (Linux and Windows)'};
ok( $deps_step, 'a Perl dependency install step exists for Linux (and Windows)' );
like( $deps_step->{run}, qr/cpanm.*--installdeps/, 'installs dependencies via cpanm --installdeps' );

# AC-4: the smoke-verify step compares compiled-binary output to source-Perl.
my $smoke_step = $step_by_name{'Smoke-verify the compiled dashboard binary (Linux only)'};
ok( $smoke_step, 'a smoke-verify step exists for Linux' );
is( $smoke_step->{if}, q{startsWith(matrix.target, 'linux-')}, 'the smoke-verify step is gated to Linux targets' );
# DD-1016: the version-only shell comparison was replaced by the shared
# functional-parity harness (t/222 guards the wiring in detail).
like( $smoke_step->{run}, qr/script\/pax-functional-parity-check/, 'delegates to the shared functional-parity harness (DD-1016)' );
like( $smoke_step->{run}, qr/--compiled pax-output\/d2\b/, 'points the harness at the real compiled binary' );
like( $smoke_step->{run}, qr/ELF 32-bit/, 'asserts the i686 binary is genuinely 32-bit, not just successfully built' );

done_testing();

__END__

=pod

=head1 NAME

211-pax-release-linux-build-wiring.t - proves DD-1013's Linux build wiring

=head1 PURPOSE

Guards DD-1013 (part of epic DDE-006): the 3 Linux matrix job entries in
C<.github/workflows/pax-release.yml> must invoke a real C<dashboard pax
build>, install a 32-bit toolchain for the i686 target using a
self-recursion-safe wrapper (a real, caught-and-fixed bug this ticket
found - a wrapper that execs the bare name C<cc> instead of an absolute
path calls itself forever), and smoke-verify each resulting binary
against the source-Perl CLI's own output before publishing it.

=head1 WHY IT EXISTS

C<t/210-pax-release-workflow-skeleton.t> (DD-1012) only proves the
skeleton's shape - trigger, matrix entries, that SOME build and upload
step exist. It says nothing about what the Linux build steps actually DO,
so a regression here (the placeholder silently reappearing, the i686
wrapper regressing to the bare-name self-recursion this ticket already
hit once, or the smoke check being removed) would only be caught by
watching a live CI run fail or hang.

=head1 WHEN TO USE

Run this file whenever the Linux portion of
C<.github/workflows/pax-release.yml> changes.

=head1 HOW TO USE

    prove -lv t/211-pax-release-linux-build-wiring.t

=head1 WHAT USES IT

C<.github/workflows/pax-release.yml>'s Linux matrix job steps are not
exercised by any other test file in this suite.

=head1 EXAMPLES

The self-recursion regression this file specifically guards against:

    # WRONG - resolves through the same PATH it was just prepended to,
    # calling itself forever:
    printf '#!/bin/sh\nexec cc -m32 "$@"\n' > "$RUNNER_TEMP/cc32/cc"

    # RIGHT - resolves the real cc FIRST, execs its absolute path:
    real_cc=$(command -v cc)
    printf '#!/bin/sh\nexec %s -m32 "$@"\n' "$real_cc" > "$RUNNER_TEMP/cc32/cc"

=cut
