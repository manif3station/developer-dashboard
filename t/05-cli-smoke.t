use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use Test::More;
use File::Temp qw(tempdir);

local $ENV{HOME} = tempdir(CLEANUP => 1);

my $perl = $^X;

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
