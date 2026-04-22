#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use Test::More;

my $root = File::Spec->catdir( $RealBin, File::Spec->updir );
my $install_sh = File::Spec->catfile( $root, 'install.sh' );
my $aptfile    = File::Spec->catfile( $root, 'aptfile' );
my $brewfile   = File::Spec->catfile( $root, 'brewfile' );

ok( -f $install_sh, 'install.sh exists at the repo root' );
ok( -f $aptfile, 'aptfile exists at the repo root' );
ok( -f $brewfile, 'brewfile exists at the repo root' );

{
    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-n', $install_sh );
    };
    is( $exit >> 8, 0, 'install.sh passes POSIX shell syntax validation' )
      or diag $stdout . $stderr;
}

my @apt_packages  = _manifest_lines($aptfile);
my @brew_packages = _manifest_lines($brewfile);
my @expected_apt_bootstrap_steps = _expected_apt_bootstrap_steps(
    packages => \@apt_packages,
);

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $target = File::Spec->catfile( $home, 'Developer-Dashboard.tar.gz' );
    my $fake_perl = File::Spec->catfile( $fake_bin, 'perl' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'ubuntu' },
        { key => 'DD_INSTALL_CPAN_TARGET', value => $target },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $exit >> 8, 0, 'install.sh succeeds on Debian-family hosts with mocked system commands' )
      or diag $stdout . $stderr;
    like(
        $stdout,
        qr/Developer Dashboard install progress/,
        'install.sh prints a visible progress board before running Debian-family bootstrap work',
    );
    if ( ( $> || 0 ) == 0 ) {
        unlike(
            $stdout,
            qr/sudo will ask for your operating-system account password, not a Developer Dashboard password/s,
            'install.sh skips the sudo password explanation when it is already running as root',
        );
    }
    else {
        like(
            $stdout,
            qr/sudo will ask for your operating-system account password, not a Developer Dashboard password/s,
            'install.sh explains the sudo password prompt before requesting system package access',
        );
    }

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --local-lib-contained $home/perl5 local::lib App::cpanminus",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            "cpanm --notest $target",
            'dashboard init',
        ],
        'install.sh follows the Debian-family bootstrap flow in manifest order',
    );

    my $bashrc = File::Spec->catfile( $home, '.bashrc' );
    ok( -f $bashrc, 'install.sh creates or updates ~/.bashrc for bash users' );
    my $bashrc_text = _slurp($bashrc);
    my $local_lib_line = qq{eval "\$("$fake_perl" -I "$home/perl5/lib/perl5" -Mlocal::lib)"};
    like(
        $bashrc_text,
        qr/\Q$local_lib_line\E/,
        'install.sh wires the local::lib bootstrap through the resolved Perl interpreter on PATH',
    );

    my ( $again_out, $again_err, $again_exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $again_exit >> 8, 0, 'install.sh remains idempotent for the selected shell rc file' )
      or diag $again_out . $again_err;
    my $bashrc_again = _slurp($bashrc);
    is(
        scalar( () = $bashrc_again =~ /\Q$local_lib_line\E/g ),
        1,
        'install.sh does not duplicate the local::lib bootstrap line on repeat runs',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                      value => $home },
        { key => 'PATH',                      value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                     value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE',    value => 'ubuntu' },
        { key => 'FAKE_NODEJS_PROVIDES_NPM',  value => '1' },
        { key => 'FAKE_NPM_PACKAGE_CONFLICTS', value => '1' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $exit >> 8, 0, 'install.sh skips the distro npm package when nodejs already provides npm and npx' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            _expected_apt_bootstrap_steps(
                packages             => \@apt_packages,
                nodejs_provides_npm => 1,
            ),
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --local-lib-contained $home/perl5 local::lib App::cpanminus",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --notest Developer::Dashboard',
            'dashboard init',
        ],
        'install.sh avoids the conflicting Debian npm package when nodejs already ships the full Node toolchain',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                  value => '/bin/zsh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'darwin' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $exit >> 8, 0, 'install.sh succeeds on macOS hosts with mocked Homebrew commands' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            'brew install ' . join( ' ', @brew_packages ),
            'brew --prefix perl',
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --local-lib-contained $home/perl5 local::lib App::cpanminus",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --notest Developer::Dashboard',
            'dashboard init',
        ],
        'install.sh follows the macOS bootstrap flow in manifest order',
    );

    my $zshrc = File::Spec->catfile( $home, '.zshrc' );
    ok( -f $zshrc, 'install.sh creates or updates ~/.zshrc for zsh users' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                  value => '/bin/sh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'debian' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $exit >> 8, 0, 'install.sh succeeds with POSIX sh users' )
      or diag $stdout . $stderr;

    ok( -f File::Spec->catfile( $home, '.profile' ), 'install.sh falls back to ~/.profile for generic POSIX sh users' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $script_copy = _slurp($install_sh);
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'ubuntu' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        open my $pipe, '|-', 'sh', '-c', "$env_prefix sh -s" or die "Unable to start streamed installer: $!";
        print {$pipe} $script_copy;
        close $pipe or die "Streamed installer exited non-zero: $?";
    };
    is( $exit >> 8, 0, 'install.sh succeeds when streamed through sh stdin without repo manifests on disk' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --local-lib-contained $home/perl5 local::lib App::cpanminus",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --notest Developer::Dashboard',
            'dashboard init',
        ],
        'streamed install.sh falls back to the embedded Debian-family manifest content',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, $_->{value} } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => $fake_bin . ':' . ( $ENV{PATH} || '' ) },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'debian' },
        { key => 'FAKE_PERL_MEETS_MIN',    value => '0' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        system( 'sh', '-c', "$env_prefix '$install_sh'" );
    };
    is( $exit >> 8, 0, 'install.sh bootstraps perlbrew when the system Perl is too old on Debian-family hosts' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            'perlbrew init',
            'perlbrew list',
            'perlbrew --notest install perl-5.38.5',
            'perlbrew install-cpanm',
            "cpanm --local-lib-contained $home/perl5 local::lib App::cpanminus",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --notest Developer::Dashboard',
            'dashboard init',
        ],
        'install.sh switches to perlbrew before the local::lib bootstrap when Debian ships an older Perl',
    );

    my $bashrc = File::Spec->catfile( $home, '.bashrc' );
    my $bashrc_text = _slurp($bashrc);
    like(
        $bashrc_text,
        qr/export PATH="\Q$home\E\/perl5\/perlbrew\/perls\/perl-5\.38\.5\/bin:\$PATH"/,
        'install.sh records the perlbrew Perl path in the active shell rc file',
    );
}

done_testing;

sub _expected_apt_bootstrap_steps {
    my (%args) = @_;
    my @packages = @{ $args{packages} || [] };
    my @non_node_packages = grep { $_ ne 'nodejs' && $_ ne 'npm' } @packages;
    my @install_lines;
    push @install_lines, 'apt-get install -y ' . join( ' ', @non_node_packages )
      if @non_node_packages;
    push @install_lines, 'apt-get install -y nodejs'
      if grep { $_ eq 'nodejs' } @packages;
    push @install_lines, 'apt-get install -y npm'
      if ( grep { $_ eq 'npm' } @packages ) && !$args{nodejs_provides_npm};
    return (
        'apt-get update',
        @install_lines,
    ) if ( $> || 0 ) == 0;
    return (
        'sudo apt-get update',
        'apt-get update',
        map( { ( "sudo $_", $_ ) } @install_lines ),
    );
}

sub _manifest_lines {
    my ($path) = @_;
    my $text = _slurp($path);
    return grep { defined && $_ ne '' }
      map {
        s/\s+#.*$//r =~ s/^\s+|\s+$//gr
      }
      grep { $_ !~ /^\s*(?:#|$)/ }
      split /\n/, $text;
}

sub _seed_fake_install_commands {
    my (%args) = @_;
    my $fake_bin = $args{fake_bin};
    my $log      = $args{log};
    my $node_marker = File::Spec->catfile( $fake_bin, 'node-toolchain.marker' );
    make_path($fake_bin);

    _write_executable(
        File::Spec->catfile( $fake_bin, 'sudo' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "sudo \$*" >> "$log"
exec "\$@"
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'apt-get' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "apt-get \$*" >> "$log"
append_marker() {
tool=\$1
grep -qx "\$tool" "$node_marker" 2>/dev/null || printf '%s\\n' "\$tool" >> "$node_marker"
}
if [ "\$1" = "install" ]; then
case " \$* " in
  *" nodejs "*)
    append_marker node
    if [ "\${FAKE_NODEJS_PROVIDES_NPM:-0}" = "1" ]; then
      append_marker npm
      append_marker npx
    fi
    ;;
esac
case " \$* " in
  *" npm "*)
    if [ "\${FAKE_NPM_PACKAGE_CONFLICTS:-0}" = "1" ]; then
      printf '%s\\n' 'E: nodejs conflicts with npm' >&2
      exit 1
    fi
    append_marker npm
    append_marker npx
    ;;
esac
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'brew' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "brew \$*" >> "$log"
if [ "\$1" = "install" ] && printf '%s ' "\$@" | grep -q ' node '; then
grep -qx 'node' "$node_marker" 2>/dev/null || printf '%s\\n' 'node' >> "$node_marker"
grep -qx 'npm' "$node_marker" 2>/dev/null || printf '%s\\n' 'npm' >> "$node_marker"
grep -qx 'npx' "$node_marker" 2>/dev/null || printf '%s\\n' 'npx' >> "$node_marker"
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'cpanm' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "cpanm \$*" >> "$log"
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'perl' ),
        <<"SH",
#!/bin/sh
if [ "\$1" = "-e" ] && [ "\$2" = "exit((\$] >= 5.038) ? 0 : 1)" ]; then
printf '%s\\n' "perl \$*" >> "$log"
if [ "\${FAKE_PERL_MEETS_MIN:-1}" = "1" ]; then
exit 0
fi
exit 1
fi
printf '%s\\n' "perl \$*" >> "$log"
printf 'export PATH="%s/perl5/bin:\$PATH"; export PERL5LIB="%s/perl5/lib/perl5\${PERL5LIB:+:\$PERL5LIB}"\\n' "\$HOME" "\$HOME"
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'dashboard' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "dashboard \$*" >> "$log"
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'node' ),
        <<"SH",
#!/bin/sh
grep -qx 'node' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' 'v22.0.0'
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'npm' ),
        <<"SH",
#!/bin/sh
grep -qx 'npm' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' '10.0.0'
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'npx' ),
        <<"SH",
#!/bin/sh
grep -qx 'npx' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' '10.0.0'
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'perlbrew' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "perlbrew \$*" >> "$log"
if [ "\$1" = "--notest" ]; then
shift
fi
case "\$1" in
init)
mkdir -p "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/perls"
exit 0
;;
list)
exit 0
;;
install)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
mkdir -p "\$root/perls/\$2/bin"
cat > "\$root/perls/\$2/bin/perl" <<'EOS'
#!/bin/sh
printf '%s\\n' "perl \$*" >> "__LOG__"
printf 'export PATH="__HOME__/perl5/bin:\$PATH"; export PERL5LIB="__HOME__/perl5/lib/perl5\${PERL5LIB:+:\$PERL5LIB}"\\n'
exit 0
EOS
perl_path="\$root/perls/\$2/bin/perl"
sed -i "s|__LOG__|$log|g; s|__HOME__|\$HOME|g" "\$perl_path"
chmod 0755 "\$perl_path"
exit 0
;;
install-cpanm)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
mkdir -p "\$root/bin"
cat > "\$root/bin/cpanm" <<'EOS'
#!/bin/sh
printf '%s\\n' "cpanm \$*" >> "__LOG__"
exit 0
EOS
sed -i "s|__LOG__|$log|g" "\$root/bin/cpanm"
chmod 0755 "\$root/bin/cpanm"
exit 0
;;
esac
exit 0
SH
    );
}

sub _log_lines {
    my ($path) = @_;
    return () if !-f $path;
    my $text = _slurp($path);
    return grep { defined && $_ ne '' } split /\n/, $text;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

sub _write_executable {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $body;
    close $fh;
    chmod 0755, $path or die "Unable to chmod $path: $!";
    return 1;
}

__END__

=head1 NAME

t/40-install-bootstrap.t - regression coverage for the repo bootstrap installer

=head1 PURPOSE

This test locks the repo-root bootstrap installer contract so the plain
F<install.sh> entrypoint, F<aptfile>, and F<brewfile> stay aligned while the
project evolves.

=head1 WHAT IT CHECKS

It verifies that the installer remains valid POSIX shell, that Debian-family
and macOS package installation flows use the repo manifests in order, that the
user-space Perl bootstrap goes through C<local::lib>, and that the correct
shell rc file receives exactly one bootstrap line.

=head1 WHY IT EXISTS

The installation path now has to work from a blank machine, so this file
protects the most important bootstrap assumptions before the heavier Docker
acceptance gates run.

=head1 WHEN TO USE

Use this test when changing the checkout bootstrap flow, the repo-root package
manifests, the user-space Perl bootstrap contract, or the shell rc file update
policy.

=head1 HOW TO USE

Run it directly through the Perl test harness during focused bootstrap work or
let it run as part of the full suite.

=head1 WHAT USES IT

It is used by the local regression suite and the release metadata gate so the
shipped bootstrap installer cannot drift away from the documented install path.

=head1 HOW TO RUN

Run it through the normal suite:

  prove -lv t/40-install-bootstrap.t

=head1 EXAMPLES

Example:

  prove -lv t/40-install-bootstrap.t

=cut
