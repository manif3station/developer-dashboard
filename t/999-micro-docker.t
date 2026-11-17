use strict;
use warnings;

# MICRO (scratch only, never merge): which of the two candidate causes
# breaks t/05 test 585 on Windows?
#   (a) the fake `docker` is an extensionless #!/bin/sh script, which
#       Windows program search never finds (PATHEXT needs .exe/.bat/.cmd);
#   (b) the test's PATH prefix uses ':' (Unix separator), so fake-bin is
#       not on the search path at all.
# The product's exact spawn is list-form system('docker','compose',...).
# Each case prints its raw outcome with diag and asserts the outcome
# expected on the platform it runs on.

use Test::More;
use Capture::Tiny qw(capture);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $is_windows = $^O eq 'MSWin32';
my $sep = $is_windows ? ';' : ':';

my $fake_bin = tempdir( CLEANUP => 1 );
diag "fake-bin: $fake_bin";

my $fake_sh = File::Spec->catfile( $fake_bin, 'docker' );
open my $fh, '>', $fake_sh or die "Unable to write $fake_sh: $!";
print {$fh} <<'SH';
#!/bin/sh
last=''
for arg in "$@"; do last="$arg"; done
if [ "$last" = 'config' ]; then
    printf 'services:\n  green: {}\n'
else
    printf 'DOCKER:%s\n' "$*"
fi
SH
close $fh;
chmod 0755, $fake_sh or die "Unable to chmod $fake_sh: $!";

my $compose = File::Spec->catfile( $fake_bin, 'compose.yml' );
open my $cfh, '>', $compose or die "Unable to write $compose: $!";
print {$cfh} "services:\n  green:\n    image: alpine\n";
close $cfh;

my $bat_content = <<'BAT';
@echo off
set "last="
for %%A in (%*) do set "last=%%A"
if "%last%"=="config" (
    echo services:
    echo   green: {}
) else (
    echo DOCKER:%*
)
BAT

# The product's exact call, with PATH set in %ENV first.
sub spawn_config {
    my ($path_value) = @_;
    local $ENV{PATH} = $path_value;
    my ( $out, $err, $exit ) = capture {
        system( 'docker', 'compose', '-f', $compose, 'config' );
        return $? >> 8;
    };
    return ( $out, $err, $exit );
}

my $good_path = $fake_bin . $sep . ( $ENV{PATH} // '' );
my $bad_path  = $fake_bin . ':' . ( $ENV{PATH} // '' );

# Case 1: extensionless fake only, correct PATH separator.
{
    my ( $out, $err, $exit ) = spawn_config($good_path);
    diag "CASE 1 extensionless-only correct-sep: exit=$exit out=[$out] err=[$err]";
    if ($is_windows) {
        ok( $exit != 0, 'CASE 1 Windows: extensionless docker is not found even with a correct PATH' );
    }
    else {
        ok( $exit == 0 && $out =~ /services:/, 'CASE 1 Unix: extensionless docker runs with a correct PATH' );
    }
}

# Case 2: add the .bat twin, correct PATH separator.
my $fake_bat = File::Spec->catfile( $fake_bin, 'docker.bat' );
open my $bfh, '>', $fake_bat or die "Unable to write $fake_bat: $!";
print {$bfh} $bat_content;
close $bfh;
{
    my ( $out, $err, $exit ) = spawn_config($good_path);
    diag "CASE 2 with docker.bat correct-sep: exit=$exit out=[$out] err=[$err]";
    ok( $exit == 0 && $out =~ /services:/, 'CASE 2: docker.bat twin is found and runs' );
}

# Case 3: extensionless fake only, WRONG separator (':' on Windows).
# Control: shows the separator matters on Windows, i.e. (b) would ALSO
# break it if the runner did not translate ':' to ';'.
unlink $fake_bat or die "Unable to remove $fake_bat: $!";
{
    my ( $out, $err, $exit ) = spawn_config($bad_path);
    diag "CASE 3 extensionless-only wrong-sep: exit=$exit out=[$out] err=[$err]";
    if ($is_windows) {
        ok( $exit != 0, 'CASE 3 Windows: extensionless docker is not found with the wrong PATH separator either' );
    }
    else {
        ok( $exit == 0 && $out =~ /services:/, 'CASE 3 Unix: colon is the correct separator, docker runs' );
    }
}

# Case 4: the exact mechanism t/05 uses — PATH prefix in the fragment,
# product spawn inside the child perl — with the docker.bat twin present.
open my $bfh2, '>', $fake_bat or die "Unable to write $fake_bat: $!";
print {$bfh2} $bat_content;
close $bfh2;
my $probe_file = File::Spec->catfile( $fake_bin, 'probe-spawn.pl' );
open my $pfh, '>', $probe_file or die "Unable to write $probe_file: $!";
print {$pfh} "use strict; use warnings;\nmy \$rc = system('docker', 'compose', '-f', q{$compose}, 'config');\nprint 'SPAWN_EXIT:', (\$? >> 8), qq{\\n};\n";
close $pfh;
{
    my $perl = $^X;
    my ( $out, $err, $exit ) = run_shell_command( "PATH='$fake_bin':\"\$PATH\" '$perl' '$probe_file'", {} );
    diag "CASE 4 runner fragment with docker.bat: exit=$exit out=[$out] err=[$err]";
    ok( $exit == 0 && $out =~ /services:/ && $out =~ /SPAWN_EXIT:0/, 'CASE 4: t/05 mechanism (PATH prefix + product spawn) works once the docker.bat twin exists' );
}

done_testing();
