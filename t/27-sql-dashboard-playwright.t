use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IO::Socket::INET;
use LWP::UserAgent;
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep);

sub _mode_octal {
    my ($path) = @_;
    my @stat = stat($path);
    return undef if !@stat;
    return sprintf( '%04o', $stat[2] & 07777 );
}

my $repo_root      = abs_path('.');
my $repo_lib       = File::Spec->catdir( $repo_root, 'lib' );
my $dashboard_bin  = File::Spec->catfile( $repo_root, 'bin', 'dashboard' );
my $host_home_root = $ENV{HOME} || '';

my $node_bin     = _find_command('node');
my $npx_bin      = _find_command('npx');
my $git_bin      = _find_command('git');
my $chromium_bin = _find_command( qw(chromium chromium-browser google-chrome google-chrome-stable) );

plan skip_all => 'SQL Playwright browser test requires node, npx, git, and Chromium on PATH'
  if !$node_bin || !$npx_bin || !$git_bin || !$chromium_bin;

my $playwright_dir = eval { _playwright_dir( $npx_bin, $host_home_root ) };
plan skip_all => "Playwright module cache is unavailable: $@"
  if !$playwright_dir;

my $home_root    = tempdir( 'dd-sql-playwright-home-XXXXXX', CLEANUP => 1, TMPDIR => 1 );
my $project_root = tempdir( 'dd-sql-playwright-project-XXXXXX', CLEANUP => 1, TMPDIR => 1 );
my $runtime_root = File::Spec->catdir( $project_root, '.developer-dashboard' );
my $config_root  = File::Spec->catdir( $runtime_root, 'config', 'sql-dashboard' );
my $local_lib    = File::Spec->catdir( $runtime_root, 'local', 'lib', 'perl5' );

make_path($runtime_root);
make_path( File::Spec->catdir( $local_lib, 'DBD' ) );

_write_text( File::Spec->catfile( $local_lib, 'DBI.pm' ), _fake_dbi_module() );
_write_text( File::Spec->catfile( $local_lib, 'DBD', 'Mock.pm' ), _fake_dbd_mock_module() );

my $dashboard_port = _reserve_port();
my $dashboard_pid;
my $dashboard_log = File::Spec->catfile( $project_root, 'dashboard-serve.log' );

eval {
    _run_command(
        command => [ $git_bin, 'init', '-q', $project_root ],
        label   => 'git init',
    );

    _run_command(
        command => [ $^X, "-I$repo_lib", $dashboard_bin, 'init' ],
        cwd     => $project_root,
        env     => { HOME => $home_root },
        label   => 'dashboard init',
    );

    $dashboard_pid = _start_dashboard_server(
        cwd           => $project_root,
        home          => $home_root,
        port          => $dashboard_port,
        repo_lib      => $repo_lib,
        dashboard_bin => $dashboard_bin,
        log_file      => $dashboard_log,
    );
    _wait_for_http("http://127.0.0.1:$dashboard_port/app/sql-dashboard");

    my ( $script_fh, $script_path ) = tempfile( 'sql-dashboard-playwright-XXXXXX', SUFFIX => '.js', TMPDIR => 1 );
    print {$script_fh} _playwright_script();
    close $script_fh or die "Unable to close Playwright script $script_path: $!";

    my $playwright_result = _run_command(
        command => [ $node_bin, $script_path ],
        env     => {
            PLAYWRIGHT_DIR => $playwright_dir,
            CHROMIUM_BIN   => $chromium_bin,
            DASHBOARD_URL  => "http://127.0.0.1:$dashboard_port/app/sql-dashboard",
        },
        label => 'Playwright sql-dashboard flow',
    );

    is( $playwright_result->{stderr}, '', 'sql-dashboard Playwright flow does not emit stderr' );
    my $payload = _json_decode( $playwright_result->{stdout} );
    ok( $payload->{ok}, 'sql-dashboard Playwright flow reports success' );

    my $saved_profile = File::Spec->catfile( $config_root, 'Playwright Profile.json' );
    ok( -f $saved_profile, 'browser-created sql profile persists to config/sql-dashboard' );
    is( _mode_octal($config_root), '0700', 'browser-created sql profile root is owner-only' );
    is( _mode_octal($saved_profile), '0600', 'browser-created sql profile file is owner-only' );
    my $saved_text = _read_text($saved_profile);
    like( $saved_text, qr/"name"\s*:\s*"Playwright Profile"/, 'saved sql profile keeps the browser-created profile name' );
    like( $saved_text, qr/"driver"\s*:\s*"DBD::Mock"/, 'saved sql profile keeps the requested driver module' );

    1;
} or do {
    my $error = $@ || 'Playwright sql-dashboard test failed';
    diag $error;
    diag _read_text($dashboard_log) if -f $dashboard_log;
    _stop_dashboard_server(
        cwd           => $project_root,
        home          => $home_root,
        repo_lib      => $repo_lib,
        dashboard_bin => $dashboard_bin,
        pid           => $dashboard_pid,
    ) if $dashboard_pid;
    die $error;
};

_stop_dashboard_server(
    cwd           => $project_root,
    home          => $home_root,
    repo_lib      => $repo_lib,
    dashboard_bin => $dashboard_bin,
    pid           => $dashboard_pid,
) if $dashboard_pid;

done_testing;

sub _playwright_script {
    return <<'JS';
const path = require('path');
const { chromium } = require(path.join(process.env.PLAYWRIGHT_DIR, 'index.js'));

async function main() {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_BIN,
    headless: true
  });
  const page = await browser.newPage();
  const pageErrors = [];
  const consoleMessages = [];
  page.on('pageerror', (error) => {
    pageErrors.push(String(error && error.stack || error));
  });
  page.on('console', (message) => {
    consoleMessages.push(message.type() + ': ' + message.text());
  });
  await page.goto(process.env.DASHBOARD_URL, { waitUntil: 'networkidle' });
  if (pageErrors.length) {
    throw new Error('page errors before interaction: ' + JSON.stringify(pageErrors));
  }

  await page.locator('#sql-profile-name').fill('Playwright Profile');
  await page.locator('#sql-profile-driver').fill('DBD::Mock');
  await page.locator('#sql-profile-dsn').fill('dbi:Mock:playwright');
  await page.locator('#sql-profile-user').fill('play_user');
  await page.locator('#sql-profile-password').fill('play-pass');
  await page.locator('#sql-profile-attrs').fill('{"RaiseError":1,"PrintError":0,"AutoCommit":1}');
  await page.locator('#sql-profile-save-password').check();
  const saveResponse = await Promise.all([
    page.waitForResponse((response) => {
      return response.url().includes('/ajax/sql-dashboard-profiles-save') && response.status() === 200;
    }),
    page.locator('#sql-profile-save').click()
  ]).then((values) => values[0]);
  const savePayload = await saveResponse.json();
  if (!savePayload || !savePayload.ok) {
    throw new Error('profile save request failed: ' + JSON.stringify(savePayload || {}));
  }
  await page.waitForFunction(() => {
    const profileTab = document.querySelector('[data-sql-profile-tab="Playwright Profile"]');
    const banner = document.getElementById('sql-banner');
    return profileTab && banner && !banner.hidden;
  });
  const profileBanner = await page.locator('#sql-banner').textContent();
  if (!String(profileBanner || '').includes('Profile saved: Playwright Profile')) {
    throw new Error('profile save banner did not confirm the saved profile');
  }

  await page.locator('[data-sql-main-tab="workspace"]').click();
  const sqlText = [
    'select * from users',
    ':~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~:',
    'STASH: prefix => "playwright-strong"',
    ':~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~:',
    'ROW: if (($row->{ID} || 0) == 2) { $row->{NAME} = { html => qq{<strong class="$stash->{prefix}">Bob</strong>} }; }',
    ':------------------------------------------------------------------------------:',
    "update users set name = 'changed'"
  ].join('\n');
  await page.locator('#sql-editor').fill(sqlText);
  const executeResponse = await Promise.all([
    page.waitForResponse((response) => {
      return response.url().includes('/ajax/sql-dashboard-execute') && response.status() === 200;
    }),
    page.locator('#sql-run').click()
  ]).then((values) => values[0]);
  const executePayload = await executeResponse.json();
  if (!executePayload || !executePayload.ok) {
    throw new Error('sql execute request failed: ' + JSON.stringify(executePayload || {}));
  }
  if (!String(executePayload.html || '').includes('playwright-strong')) {
    throw new Error('sql execute payload missed the programmable row html: ' + JSON.stringify(executePayload));
  }
  if (!String(executePayload.html || '').includes('Rows affected: 3')) {
    throw new Error('sql execute payload missed the affected-row summary: ' + JSON.stringify(executePayload));
  }
  await page.waitForTimeout(500);
  if (pageErrors.length) {
    throw new Error('page errors after SQL execution: ' + JSON.stringify(pageErrors));
  }
  const executeDom = await page.evaluate(() => {
    const result = document.getElementById('sql-result-html');
    const info = document.getElementById('sql-result-info');
    return {
      resultHtml: result ? result.innerHTML : '',
      infoText: info ? info.textContent : ''
    };
  });
  if (!String(executeDom.resultHtml || '').includes('playwright-strong')) {
    throw new Error('sql execute DOM missed the programmable row html: ' + JSON.stringify(executeDom));
  }
  if (!String(executeDom.resultHtml || '').includes('Rows affected: 3')) {
    throw new Error('sql execute DOM missed the affected-row summary: ' + JSON.stringify(executeDom));
  }
  if (!String(executeDom.infoText || '').includes('Playwright Profile')) {
    throw new Error('sql execute DOM missed the active profile details: ' + JSON.stringify(executeDom));
  }

  const workspaceUrl = page.url();
  if (!workspaceUrl.includes('profile=Playwright+Profile')) {
    throw new Error('share URL did not capture the active profile');
  }
  if (!workspaceUrl.includes('sql=')) {
    throw new Error('share URL did not capture the current SQL text');
  }

  const schemaResponse = await Promise.all([
    page.waitForResponse((response) => {
      return response.url().includes('/ajax/sql-dashboard-schema-browse') && response.status() === 200;
    }),
    page.locator('#sql-open-schema').click()
  ]).then((values) => values[0]);
  const schemaPayload = await schemaResponse.json();
  if (!schemaPayload || !schemaPayload.ok) {
    throw new Error('schema browse request failed: ' + JSON.stringify(schemaPayload || {}));
  }
  await page.waitForTimeout(500);
  const tableTabsText = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('[data-sql-table-tab]')).map((node) => node.textContent || '');
  });
  if (!tableTabsText.includes('USERS')) {
    throw new Error('schema browse DOM missed the USERS table tab: ' + JSON.stringify(tableTabsText));
  }
  await page.locator('[data-sql-table-tab="USERS"]').click();
  await page.waitForTimeout(250);
  const columnText = await page.locator('#sql-column-list').textContent();
  if (!String(columnText || '').includes('ID') || !String(columnText || '').includes('NAME')) {
    throw new Error('schema browse DOM missed the expected columns: ' + JSON.stringify({ columnText }));
  }

  const schemaUrl = page.url();
  if (!schemaUrl.includes('tab=schema')) {
    throw new Error('schema route did not update the browser URL');
  }

  await page.goto(schemaUrl, { waitUntil: 'networkidle' });
  await page.waitForTimeout(500);
  const restoredState = await page.evaluate(() => {
    const sql = document.getElementById('sql-editor');
    const badge = document.getElementById('sql-active-profile');
    return {
      sql: sql ? sql.value : '',
      badge: badge ? badge.textContent : ''
    };
  });
  if (!String(restoredState.sql || '').includes('select * from users')) {
    throw new Error('reloaded share URL did not restore the current SQL text: ' + JSON.stringify(restoredState));
  }
  if (!String(restoredState.badge || '').includes('Playwright Profile')) {
    throw new Error('reloaded share URL did not restore the active profile: ' + JSON.stringify(restoredState));
  }

  await browser.close();
  process.stdout.write(JSON.stringify({ ok: true, consoleMessages, pageErrors }));
}

main().catch((error) => {
  process.stderr.write(String(error && error.stack || error) + '\n');
  process.exit(1);
});
JS
}

sub _fake_dbd_mock_module {
    return <<'PERL';
package DBD::Mock;

use strict;
use warnings;

our $VERSION = '1.00';

1;
PERL
}

sub _fake_dbi_module {
    return <<'PERL';
package DBI;

use strict;
use warnings;

sub connect {
    my ( $class, $dsn, $user, $pass, $attrs ) = @_;
    die "Unsupported DSN: $dsn\n" if !defined $dsn || $dsn !~ /^dbi:Mock:/i;
    return bless {
        dsn   => $dsn,
        user  => $user,
        pass  => $pass,
        attrs => $attrs || {},
    }, 'DBI::db';
}

package DBI::db;

use strict;
use warnings;

sub prepare {
    my ( $self, $sql ) = @_;
    return bless {
        db  => $self,
        sql => $sql,
    }, 'DBI::st';
}

sub table_info {
    return bless {
        mode => 'tables',
    }, 'DBI::st';
}

sub column_info {
    my ( $self, undef, undef, $table_name, undef ) = @_;
    return bless {
        mode       => 'columns',
        table_name => $table_name,
    }, 'DBI::st';
}

sub disconnect { return 1 }

package DBI::st;

use strict;
use warnings;

sub execute {
    my ($self) = @_;
    if ( ( $self->{mode} || '' ) eq 'tables' ) {
        $self->{NAME} = [ 'TABLE_NAME' ];
        $self->{_rows} = [
            { TABLE_NAME => 'USERS' },
            { TABLE_NAME => 'ORDERS' },
        ];
        return 1;
    }
    if ( ( $self->{mode} || '' ) eq 'columns' ) {
        $self->{NAME} = [ 'COLUMN_NAME', 'DATA_TYPE', 'DATA_LENGTH' ];
        $self->{_rows} = [
            { COLUMN_NAME => 'ID',   DATA_TYPE => 'NUMBER',   DATA_LENGTH => 22 },
            { COLUMN_NAME => 'NAME', DATA_TYPE => 'VARCHAR2', DATA_LENGTH => 255 },
        ];
        return 1;
    }

    my $sql = $self->{sql} || '';
    if ( $sql =~ /^\s*select\b/i ) {
        $self->{NAME} = [ 'ID', 'NAME' ];
        $self->{_rows} = [
            { ID => 1, NAME => 'Alice' },
            { ID => 2, NAME => 'Bob' },
        ];
        return 1;
    }

    $self->{NAME}           = [];
    $self->{_rows}          = [];
    $self->{_rows_affected} = 3;
    return 1;
}

sub fetchrow_hashref {
    my ($self) = @_;
    return shift @{ $self->{_rows} || [] };
}

sub rows {
    my ($self) = @_;
    return $self->{_rows_affected} if exists $self->{_rows_affected};
    return scalar @{ $self->{_rows} || [] };
}

1;
PERL
}

sub _find_command {
    my @candidates = @_;
    for my $candidate (@candidates) {
        next if !defined $candidate || $candidate eq '';
        for my $dir ( File::Spec->path() ) {
            my $path = File::Spec->catfile( $dir, $candidate );
            return $path if -f $path && -x $path;
        }
    }
    return undef;
}

sub _playwright_dir {
    my ( $npx_bin, $home_root ) = @_;
    my ( $stdout, $stderr, $exit ) = capture {
        system( $npx_bin, 'playwright', '--version' );
    };
    die "Unable to resolve Playwright with npx: $stderr$stdout"
      if $exit != 0;
    my @matches = sort glob( File::Spec->catfile( $home_root, '.npm', '_npx', '*', 'node_modules', 'playwright' ) );
    die "Unable to find cached Playwright module directory under $home_root/.npm/_npx\n"
      if !@matches;
    return $matches[-1];
}

sub _reserve_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to reserve a local TCP port: $!";
    my $port = $socket->sockport();
    close $socket or die "Unable to close reserved TCP port socket for $port: $!";
    return $port;
}

sub _run_command {
    my (%args) = @_;
    my $command = $args{command} || [];
    die "run_command requires a command array reference\n" if ref($command) ne 'ARRAY' || !@{$command};

    my $cwd = getcwd();
    my ( $stdout, $stderr, $exit ) = capture {
        local %ENV = ( %ENV, %{ $args{env} || {} } );
        if ( defined $args{cwd} && $args{cwd} ne '' ) {
            chdir $args{cwd} or die "Unable to chdir to $args{cwd}: $!";
        }
        system( @{$command} );
        chdir $cwd or die "Unable to restore cwd to $cwd: $!";
        return $? >> 8;
    };

    is( $exit, 0, ( $args{label} || 'command' ) . ' exits successfully' ) or diag $stderr . $stdout;
    return {
        stdout => $stdout,
        stderr => $stderr,
        exit   => $exit,
    };
}

sub _start_dashboard_server {
    my (%args) = @_;
    my $pid = fork();
    die "Unable to fork dashboard server: $!" if !defined $pid;
    if ( $pid == 0 ) {
        local %ENV = %ENV;
        $ENV{HOME} = $args{home};
        chdir $args{cwd} or die "Unable to chdir to $args{cwd}: $!";
        open STDOUT, '>', $args{log_file} or die "Unable to write $args{log_file}: $!";
        open STDERR, '>&STDOUT' or die "Unable to dup dashboard log: $!";
        exec $^X, "-I$args{repo_lib}", $args{dashboard_bin}, 'serve', '--foreground', '--host', '127.0.0.1', '--port', $args{port}, '--workers', '1'
          or die "Unable to exec dashboard server: $!";
    }
    return $pid;
}

sub _stop_dashboard_server {
    my (%args) = @_;
    return if !$args{pid};
    local %ENV = %ENV;
    $ENV{HOME} = $args{home};
    my ( $stdout, $stderr, $exit ) = capture {
        chdir $args{cwd} or die "Unable to chdir to $args{cwd}: $!";
        system( $^X, "-I$args{repo_lib}", $args{dashboard_bin}, 'stop' );
        return $? >> 8;
    };
    my $waited = waitpid( $args{pid}, WNOHANG );
    if ( $waited == 0 && kill 0, $args{pid} ) {
        kill 'TERM', $args{pid};
        for ( 1 .. 20 ) {
            my $done = waitpid( $args{pid}, WNOHANG );
            last if $done == $args{pid};
            sleep 0.1;
        }
    }
    if ( kill 0, $args{pid} ) {
        kill 'KILL', $args{pid};
    }
    waitpid( $args{pid}, 0 );
    return {
        stdout => $stdout,
        stderr => $stderr,
        exit   => $exit,
    };
}

sub _wait_for_http {
    my ($url) = @_;
    my $ua = LWP::UserAgent->new(
        timeout  => 2,
        max_redirect => 0,
    );
    for ( 1 .. 60 ) {
        my $response = $ua->get($url);
        return 1 if $response->is_success;
        sleep 0.25;
    }
    die "Timed out waiting for HTTP endpoint $url\n";
}

sub _write_text {
    my ( $path, $text ) = @_;
    my ( $volume, $directories, undef ) = File::Spec->splitpath($path);
    my $dir = File::Spec->catpath( $volume, $directories, '' );
    make_path($dir) if $dir ne '' && !-d $dir;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $text;
    close $fh or die "Unable to close $path: $!";
    return $path;
}

sub _read_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $text;
}

sub _json_decode {
    my ($text) = @_;
    require Developer::Dashboard::JSON;
    return Developer::Dashboard::JSON::json_decode($text);
}

__END__

=head1 NAME

27-sql-dashboard-playwright.t - browser coverage for the seeded sql-dashboard bookmark

=head1 DESCRIPTION

This test starts an isolated project-local runtime, injects a fake DBI/DBD
stack under C<.developer-dashboard/local/lib/perl5>, and drives the seeded
C<sql-dashboard> bookmark through a real Chromium Playwright session while
verifying that browser-created saved profiles persist with owner-only
permissions.

=cut
