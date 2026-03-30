use strict;
use warnings;

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode);
use File::Path qw(make_path);
use File::Spec;
use Test::More;
use File::Temp qw(tempdir);

local $ENV{HOME} = tempdir(CLEANUP => 1);
local $ENV{PERL5LIB} = join ':', grep { defined && $_ ne '' } '/home/mv/perl5/lib/perl5', ( $ENV{PERL5LIB} || () );

my $perl = $^X;
my $repo = getcwd();

my $init = _run("$perl -Ilib bin/dashboard init");
like($init, qr/runtime_root/, 'dashboard init works');

my $pages = _run("$perl -Ilib bin/dashboard page list");
like($pages, qr/welcome/, 'welcome page listed');

my $page_source = _run("$perl -Ilib bin/dashboard page source welcome");
like($page_source, qr/^BOOKMARK:\s+welcome/m, 'page source prefers saved page ids over token decoding');

my $collector = _run("$perl -Ilib bin/dashboard collector run example.collector");
like($collector, qr/example collector output/, 'collector run works');

my $auth_add = _run("$perl -Ilib bin/dashboard auth add-user helper helper-pass-123");
like($auth_add, qr/"username"\s*:\s*"helper"/, 'auth add-user works');

my $auth_list = _run("$perl -Ilib bin/dashboard auth list-users");
like($auth_list, qr/"username"\s*:\s*"helper"/, 'auth list-users works');

my $indicator_refresh = _run("$perl -Ilib bin/dashboard indicator refresh-core");
like($indicator_refresh, qr/docker|project|git/, 'indicator refresh-core works');

my $ps1 = _run("$perl -Ilib bin/dashboard ps1 --jobs 1");
like($ps1, qr/\(1 jobs\)|developer-dashboard:master| D /, 'ps1 command works');
my $ps1_extended = _run("$perl -Ilib bin/dashboard ps1 --jobs 1 --mode extended --color");
like($ps1_extended, qr/\e\[|\(1 jobs\)/, 'ps1 supports extended/color modes');

my $collector_inspect = _run("$perl -Ilib bin/dashboard collector inspect example.collector");
like($collector_inspect, qr/"job"|"status"/, 'collector inspect works');

my ( $usage_stdout, $usage_stderr, $usage_exit ) = capture {
    system $perl, '-Ilib', 'bin/dashboard';
    return $? >> 8;
};
is( $usage_exit, 1, 'dashboard with no arguments exits with usage status' );
like( $usage_stdout . $usage_stderr, qr/SYNOPSIS|dashboard init/, 'dashboard with no arguments renders POD-backed usage' );

my $help = _run("$perl -Ilib bin/dashboard help");
like($help, qr/Description:/, 'dashboard help renders the fuller POD help');

my $bookmarks_root = _run("$perl -Ilib bin/dashboard path resolve bookmarks_root");
is( $bookmarks_root, File::Spec->catdir( $ENV{HOME}, '.developer-dashboard', 'dashboards' ) . "\n", 'dashboard path resolve supports bookmarks_root alias' );

my $shell_bootstrap = _run("$perl -Ilib bin/dashboard shell bash");
like( $shell_bootstrap, qr/dashboard path resolve \"\$1\"/, 'dashboard shell bootstrap resolves named path aliases before project search' );
my $which_dir_bookmarks = _run("bash -lc 'eval \"\$($perl -Ilib bin/dashboard shell bash)\"; which_dir bookmarks_root'");
is( $which_dir_bookmarks, $bookmarks_root, 'which_dir resolves bookmarks_root through the shell helper' );
my $cdr_bookmarks = _run("bash -lc 'eval \"\$($perl -Ilib bin/dashboard shell bash)\"; cdr bookmarks_root; pwd'");
is( $cdr_bookmarks, $bookmarks_root, 'cdr navigates to bookmarks_root through the shell helper' );

my $docker_green_root = File::Spec->catdir( $ENV{HOME}, '.developer-dashboard', 'config', 'docker', 'green' );
make_path($docker_green_root);
open my $docker_green_fh, '>', File::Spec->catfile( $docker_green_root, 'development.compose.yml' )
  or die "Unable to write docker green development compose file: $!";
print {$docker_green_fh} "services:\n  green:\n    image: alpine\n";
close $docker_green_fh;
my $docker_dry_run = _run("$perl -Ilib bin/dashboard docker compose --dry-run up -d --build green");
my $docker_dry_run_data = json_decode($docker_dry_run);
ok( grep( { $_ eq '--build' } @{ $docker_dry_run_data->{command} } ), 'dashboard docker compose leaves docker passthrough flags such as --build untouched' );
ok( grep( { $_ eq 'green' } @{ $docker_dry_run_data->{services} } ), 'dashboard docker compose still infers service names from passthrough args when docker flags are present' );

my $open_root = File::Spec->catdir( $ENV{HOME}, 'open-file-fixtures' );
make_path($open_root);
my $open_target = File::Spec->catfile( $open_root, 'alpha-notes.txt' );
open my $open_fh, '>', $open_target or die "Unable to write $open_target: $!";
print {$open_fh} "alpha\n";
close $open_fh;

my $open_print = _run("$perl -Ilib bin/dashboard open-file --print '$open_root' alpha");
like($open_print, qr/\Q$open_target\E/, 'dashboard open-file prints matching files');

my $of_print = _run("$perl -Ilib bin/dashboard of --print '$open_root' alpha");
like($of_print, qr/\Q$open_target\E/, 'dashboard of is shorthand for open-file');

my $standalone_of_print = _run("$perl -Ilib bin/of --print '$open_root' alpha");
is( $standalone_of_print, $of_print, 'standalone of matches dashboard of output' );

my $standalone_open_file = _run("$perl -Ilib bin/open-file --print '$open_root' alpha");
is( $standalone_open_file, $open_print, 'standalone open-file matches dashboard open-file output' );

my $perl_root = File::Spec->catdir( $open_root, 'lib', 'My' );
make_path($perl_root);
my $perl_target = File::Spec->catfile( $perl_root, 'App.pm' );
open my $perl_fh, '>', $perl_target or die "Unable to write $perl_target: $!";
print {$perl_fh} "package My::App;\n1;\n";
close $perl_fh;
local $ENV{PERL5LIB} = join ':', grep { defined && $_ ne '' } File::Spec->catdir( $open_root, 'lib' ), $ENV{PERL5LIB};
my $perl_module = _run("$perl -Ilib bin/dashboard open-file --print My::App");
like($perl_module, qr/\Q$perl_target\E/, 'dashboard open-file resolves Perl module names');

my $java_root = File::Spec->catdir( $open_root, 'src', 'com', 'example' );
make_path($java_root);
my $java_target = File::Spec->catfile( $java_root, 'App.java' );
open my $java_fh, '>', $java_target or die "Unable to write $java_target: $!";
print {$java_fh} "package com.example;\nclass App {}\n";
close $java_fh;
my $java_class = _run("cd '$open_root' && $perl -I'$repo/lib' '$repo/bin/dashboard' open-file --print com.example.App");
like($java_class, qr/\Q$java_target\E/, 'dashboard open-file resolves Java class names');

my $json_value = _run(qq{printf '{"alpha":{"beta":2}}' | $perl -Ilib bin/dashboard pjq alpha.beta});
is( $json_value, "2\n", 'pjq extracts scalar JSON values' );
my $json_file = File::Spec->catfile( $open_root, 'sample.json' );
open my $json_fh, '>', $json_file or die "Unable to write $json_file: $!";
print {$json_fh} qq|{"alpha":{"beta":2}}|;
close $json_fh;
my $json_root = _run("$perl -Ilib bin/dashboard pjq '\$d' '$json_file'");
is_deeply( json_decode($json_root), { alpha => { beta => 2 } }, 'pjq accepts file then root query with order-independent args' );
my $json_root_stdin = _run("cat '$json_file' | $perl -Ilib bin/dashboard pjq '\$d'");
is( $json_root_stdin, $json_root, 'pjq returns the same whole-document result from stdin and file input' );
my $json_direct = _run(qq{printf '{"alpha":{"beta":2}}' | $perl -Ilib bin/pjq alpha.beta});
is( $json_direct, $json_value, 'standalone pjq matches dashboard pjq output' );

my $yaml_value = _run(qq{printf 'alpha:\\n  beta: 3\\n' | $perl -Ilib bin/dashboard pyq alpha.beta});
is( $yaml_value, "3\n", 'pyq extracts scalar YAML values' );
my $yaml_file = File::Spec->catfile( $open_root, 'sample.yaml' );
open my $yaml_fh, '>', $yaml_file or die "Unable to write $yaml_file: $!";
print {$yaml_fh} "alpha:\n  beta: 3\n";
close $yaml_fh;
my $yaml_root = _run("$perl -Ilib bin/dashboard pyq '$yaml_file' '\$d'");
is_deeply( json_decode($yaml_root), { alpha => { beta => '3' } }, 'pyq accepts file then root query with order-independent args' );
my $yaml_root_stdin = _run("cat '$yaml_file' | $perl -Ilib bin/dashboard pyq '\$d'");
is( $yaml_root_stdin, $yaml_root, 'pyq returns the same whole-document result from stdin and file input' );
my $yaml_direct = _run(qq{printf 'alpha:\\n  beta: 3\\n' | $perl -Ilib bin/pyq alpha.beta});
is( $yaml_direct, $yaml_value, 'standalone pyq matches dashboard pyq output' );

my $toml_value = _run(qq{printf '[alpha]\\nbeta = 4\\n' | $perl -Ilib bin/dashboard ptomq alpha.beta});
is( $toml_value, "4\n", 'ptomq extracts scalar TOML values' );
my $toml_file = File::Spec->catfile( $open_root, 'sample.toml' );
open my $toml_fh, '>', $toml_file or die "Unable to write $toml_file: $!";
print {$toml_fh} "[alpha]\nbeta = 4\n";
close $toml_fh;
my $toml_root = _run("$perl -Ilib bin/dashboard ptomq '\$d' '$toml_file'");
is_deeply( json_decode($toml_root), { alpha => { beta => 4 } }, 'ptomq accepts file then root query with order-independent args' );
my $toml_root_stdin = _run("cat '$toml_file' | $perl -Ilib bin/dashboard ptomq '\$d'");
is( $toml_root_stdin, $toml_root, 'ptomq returns the same whole-document result from stdin and file input' );
my $toml_direct = _run(qq{printf '[alpha]\\nbeta = 4\\n' | $perl -Ilib bin/ptomq alpha.beta});
is( $toml_direct, $toml_value, 'standalone ptomq matches dashboard ptomq output' );

my $props_value = _run(qq{printf 'alpha.beta=5\\nname = demo\\n' | $perl -Ilib bin/dashboard pjp alpha.beta});
is( $props_value, "5\n", 'pjp extracts scalar Java properties values' );
my $props_file = File::Spec->catfile( $open_root, 'sample.properties' );
open my $props_fh, '>', $props_file or die "Unable to write $props_file: $!";
print {$props_fh} "alpha.beta=5\nname = demo\n";
close $props_fh;
my $props_root = _run("$perl -Ilib bin/dashboard pjp '$props_file' '\$d'");
is_deeply( json_decode($props_root), { 'alpha.beta' => '5', name => 'demo' }, 'pjp accepts file then root query with order-independent args' );
my $props_root_stdin = _run("cat '$props_file' | $perl -Ilib bin/dashboard pjp '\$d'");
is( $props_root_stdin, $props_root, 'pjp returns the same whole-document result from stdin and file input' );
my $props_direct = _run(qq{printf 'alpha.beta=5\\nname = demo\\n' | $perl -Ilib bin/pjp alpha.beta});
is( $props_direct, $props_value, 'standalone pjp matches dashboard pjp output' );

my $cli_root = File::Spec->catdir( $ENV{HOME}, '.developer-dashboard', 'cli' );
make_path($cli_root);
my $ext = File::Spec->catfile( $cli_root, 'foobar' );
open my $ext_fh, '>', $ext or die "Unable to write $ext: $!";
print {$ext_fh} <<'SH';
#!/bin/sh
input="$(cat)"
printf 'argv:%s|stdin:%s\n' "$*" "$input"
SH
close $ext_fh;
chmod 0755, $ext or die "Unable to chmod $ext: $!";

my ( $ext_stdout, $ext_stderr, $ext_exit ) = capture {
    open my $pipe, '|-', $perl, '-Ilib', 'bin/dashboard', 'foobar', 'one', 'two'
      or die "Unable to exec dashboard extension: $!";
    print {$pipe} "hello-extension";
    close $pipe or die "dashboard extension failed: $!";
    return $? >> 8;
};
is( $ext_exit, 0, 'user CLI extension exits successfully' );
is( $ext_stderr, '', 'user CLI extension keeps stderr clean' );
like( $ext_stdout, qr/^argv:one two\|stdin:hello-extension$/m, 'user CLI extension receives argv and stdin passthrough' );

done_testing;

sub _run {
    my ($cmd) = @_;
    my ( $stdout, $stderr, $exit_code ) = capture {
        system 'sh', '-c', $cmd;
        return $? >> 8;
    };
    is( $exit_code, 0, "command succeeded: $cmd" );
    return $stdout . $stderr;
}

__END__

=head1 NAME

05-cli-smoke.t - CLI smoke tests for dashboard

=head1 DESCRIPTION

This test verifies the main command-line entrypoints for Developer Dashboard.

=cut
