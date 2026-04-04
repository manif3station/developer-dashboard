use strict;
use warnings;
use utf8;

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Encode qw(decode_utf8);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::CLI::Query ();
use Developer::Dashboard::InternalCLI ();
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Runtime::Result ();
use Developer::Dashboard::SkillDispatcher;
use Developer::Dashboard::SkillManager;

local $ENV{HOME} = tempdir( CLEANUP => 1 );

my $paths = Developer::Dashboard::PathRegistry->new( home => $ENV{HOME} );

is( $paths->app_name, 'developer-dashboard', 'path registry exposes the default app name' );
is( $paths->register_named_paths('nope'), $paths, 'register_named_paths ignores non-hash input' );
is( $paths->unregister_named_path(''), $paths, 'unregister_named_path ignores empty names' );
is_deeply( $paths->named_paths, {}, 'named_paths starts empty' );
is( $paths->resolve_any('missing-one', 'missing-two'), undef, 'resolve_any returns undef when nothing exists' );
is( $paths->is_home_runtime_path(''), 0, 'is_home_runtime_path rejects empty input' );
is( $paths->is_home_runtime_path('/tmp/outside'), 0, 'is_home_runtime_path rejects non-home runtime paths' );
is( $paths->secure_dir_permissions('/tmp/outside'), '/tmp/outside', 'secure_dir_permissions ignores non-home runtime paths' );
is( $paths->secure_file_permissions('/tmp/outside-file'), '/tmp/outside-file', 'secure_file_permissions ignores non-home runtime files' );
ok( -d $paths->cache_root, 'cache_root creates the cache directory' );
ok( -d $paths->temp_root, 'temp_root creates the temp directory' );
ok( -d $paths->sessions_root, 'sessions_root creates the sessions directory' );
ok( -d $paths->skill_root('alpha-skill'), 'skill_root creates an isolated skill directory' );
is( $paths->_expand_home(undef), undef, '_expand_home leaves undef untouched' );
like(
    _dies( sub { $paths->skill_root('') } ),
    qr/Missing skill name/,
    'skill_root rejects an empty skill name',
);

is_deeply(
    Developer::Dashboard::InternalCLI::helper_aliases(),
    {
        pjq   => 'jq',
        pyq   => 'yq',
        ptomq => 'tomq',
        pjp   => 'propq',
    },
    'internal CLI exposes the expected helper aliases',
);
is( Developer::Dashboard::InternalCLI::canonical_helper_name('pjq'), 'jq', 'legacy helper alias normalizes to jq' );
is( Developer::Dashboard::InternalCLI::canonical_helper_name('xmlq'), 'xmlq', 'current helper name stays unchanged' );
is( Developer::Dashboard::InternalCLI::canonical_helper_name('bogus'), '', 'unsupported helper names normalize to empty string' );
like(
    _dies( sub { Developer::Dashboard::InternalCLI::helper_path( paths => $paths, name => 'bogus' ) } ),
    qr/Unsupported helper command/,
    'helper_path rejects unsupported helper names',
);
like(
    _dies( sub { Developer::Dashboard::InternalCLI::helper_content('bogus') } ),
    qr/Unsupported helper command/,
    'helper_content rejects unsupported helper names',
);
for my $helper ( Developer::Dashboard::InternalCLI::helper_names() ) {
    my $content = Developer::Dashboard::InternalCLI::helper_content($helper);
    if ( $helper eq 'of' || $helper eq 'open-file' ) {
        like(
            $content,
            qr/\Qrun_open_file_command( args => \@ARGV );\E/,
            "helper_content renders the embedded $helper open-file helper body",
        );
    }
    else {
        like(
            $content,
            qr/\Qrun_query_command( command => '$helper', args => \@ARGV );\E/,
            "helper_content renders the embedded $helper query helper body",
        );
    }
}
my $seeded_helpers = Developer::Dashboard::InternalCLI::ensure_helpers( paths => $paths );
my @helper_names = Developer::Dashboard::InternalCLI::helper_names();
is( scalar(@$seeded_helpers), scalar(@helper_names), 'ensure_helpers writes every embedded helper once' );
ok( grep( $_ =~ m{/\Qof\E$}, @$seeded_helpers ), 'ensure_helpers writes the private of helper' );
ok( grep( $_ =~ m{/\Qopen-file\E$}, @$seeded_helpers ), 'ensure_helpers writes the private open-file helper' );

is_deeply(
    [ Developer::Dashboard::CLI::Query::_split_query_args() ],
    [ '', '' ],
    '_split_query_args returns empty path/file when no args are supplied',
);
is_deeply(
    [ Developer::Dashboard::CLI::Query::_split_query_args( 'alpha.beta', 'missing.file' ) ],
    [ 'alpha.beta', '' ],
    '_split_query_args leaves a non-file argument as the query path',
);

my $query_file = File::Spec->catfile( $ENV{HOME}, 'query.json' );
_write_file( $query_file, qq|{"alpha":{"beta":2}}\n| );
is(
    Developer::Dashboard::CLI::Query::_read_query_input($query_file),
    qq|{"alpha":{"beta":2}}\n|,
    '_read_query_input reads explicit files',
);
{
    local *STDIN;
    open STDIN, '<', \$query_file or die "Unable to open scalar STDIN: $!";
    is(
        Developer::Dashboard::CLI::Query::_read_query_input(''),
        $query_file,
        '_read_query_input reads STDIN when no file is supplied',
    );
}

is_deeply(
    Developer::Dashboard::CLI::Query::_parse_query_input( command => 'pjq', text => qq|{"alpha":{"beta":2}}| ),
    { alpha => { beta => 2 } },
    '_parse_query_input supports the legacy JSON alias',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_query_input( command => 'pyq', text => "alpha:\n  beta: 3\n" ),
    { alpha => { beta => 3 } },
    '_parse_query_input supports the legacy YAML alias',
);
is_deeply(
    scalar( Developer::Dashboard::CLI::Query::_parse_query_input( command => 'ptomq', text => "[alpha]\nbeta = 4\n" ) ),
    { alpha => { beta => 4 } },
    '_parse_query_input supports the legacy TOML alias',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_query_input( command => 'pjp', text => "alpha.beta=5\n" ),
    { 'alpha.beta' => '5' },
    '_parse_query_input supports the legacy properties alias',
);
like(
    _dies( sub { Developer::Dashboard::CLI::Query::_parse_query_input( command => 'bogus', text => '' ) } ),
    qr/Unsupported data query command/,
    '_parse_query_input rejects unsupported formats',
);
is_deeply( Developer::Dashboard::CLI::Query::_extract_query_path( { alpha => 1 }, '$d' ), { alpha => 1 }, '_extract_query_path returns the whole document for $d' );
is( Developer::Dashboard::CLI::Query::_extract_query_path( { 'alpha.beta' => 'joined' }, 'alpha.beta' ), 'joined', '_extract_query_path returns a direct dotted hash key when present' );
is( Developer::Dashboard::CLI::Query::_extract_query_path( [ [ 'a', 'b' ] ], '0.1' ), 'b', '_extract_query_path supports array traversal' );
like(
    _dies( sub { Developer::Dashboard::CLI::Query::_extract_query_path( { alpha => {} }, 'alpha.beta' ) } ),
    qr/Missing path segment 'beta'/,
    '_extract_query_path dies for missing hash keys',
);
like(
    _dies( sub { Developer::Dashboard::CLI::Query::_extract_query_path( [1], 'x' ) } ),
    qr/Array index 'x' is invalid/,
    '_extract_query_path rejects non-numeric array indexes',
);
like(
    _dies( sub { Developer::Dashboard::CLI::Query::_extract_query_path( 'plain', 'alpha' ) } ),
    qr/does not resolve through a nested structure/,
    '_extract_query_path rejects traversal through scalars',
);
{
    my ( $stdout ) = capture { Developer::Dashboard::CLI::Query::_print_query_value( { ok => 1 } ) };
    like( $stdout, qr/"ok"\s*:\s*1/s, '_print_query_value renders structures as JSON' );
}
{
    my ( $stdout ) = capture { Developer::Dashboard::CLI::Query::_print_query_value(undef) };
    is( $stdout, "\n", '_print_query_value prints a newline for undef scalars' );
}
is(
    Developer::Dashboard::CLI::Query::_unescape_properties("\\t\\n\\r\\f\\\\"),
    "\t\n\r\f\\",
    '_unescape_properties decodes all supported escape sequences',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_java_properties("! comment\nalpha=one\\\ntwo\nblank\n"),
    { alpha => 'onetwo', blank => '' },
    '_parse_java_properties handles comments, continuations, and blank values',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_ini("name = root\n[alpha]\nbeta = 1\n"),
    {
        _global => { name => 'root' },
        alpha   => { beta => '1' },
    },
    '_parse_ini captures global keys and named sections',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_csv("a,b\n1,2\n\n"),
    [ [ 'a', 'b' ], [ '1', '2' ] ],
    '_parse_csv skips empty trailing rows',
);
is_deeply(
    Developer::Dashboard::CLI::Query::_parse_xml('<root/>'),
    { _raw => '<root/>' },
    '_parse_xml preserves the raw XML payload',
);

local $ENV{RESULT} = '';
is_deeply( Developer::Dashboard::Runtime::Result::current(), {}, 'Runtime::Result current returns an empty hash for empty RESULT' );
is( Developer::Dashboard::Runtime::Result::has(''), 0, 'Runtime::Result has rejects empty names' );
is( Developer::Dashboard::Runtime::Result::entry(''), undef, 'Runtime::Result entry rejects empty names' );
is( Developer::Dashboard::Runtime::Result::stdout('missing'), '', 'Runtime::Result stdout returns empty string for missing names' );
is( Developer::Dashboard::Runtime::Result::stderr('missing'), '', 'Runtime::Result stderr returns empty string for missing names' );
is( Developer::Dashboard::Runtime::Result::exit_code('missing'), undef, 'Runtime::Result exit_code returns undef for missing names' );
is( Developer::Dashboard::Runtime::Result::last_name(), undef, 'Runtime::Result last_name returns undef when RESULT is empty' );
is( Developer::Dashboard::Runtime::Result::last_entry(), undef, 'Runtime::Result last_entry returns undef when RESULT is empty' );
is( Developer::Dashboard::Runtime::Result::report(), '', 'Runtime::Result report returns an empty string for empty RESULT' );
{
    local $0 = '';
    local $ENV{DEVELOPER_DASHBOARD_COMMAND} = 'env-command';
    is( Developer::Dashboard::Runtime::Result::_command_name(), 'env-command', '_command_name falls back to the command env var when $0 is empty' );
}
{
    local $0 = '';
    local $ENV{DEVELOPER_DASHBOARD_COMMAND} = '';
    is( Developer::Dashboard::Runtime::Result::_command_name(), 'dashboard', '_command_name falls back to dashboard when neither $0 nor env provide a name' );
}
{
    local $0 = '/tmp/custom-report/run';
    local $ENV{DEVELOPER_DASHBOARD_COMMAND} = 'ignored';
    is( Developer::Dashboard::Runtime::Result::_command_name(), 'custom-report', '_command_name uses the parent directory for run-style executables' );
}
{
    local $0 = '/run';
    local $ENV{DEVELOPER_DASHBOARD_COMMAND} = 'env-fallback';
    is( Developer::Dashboard::Runtime::Result::_command_name(), 'env-fallback', '_command_name falls back to env when run-style paths have no usable parent name' );
}
{
    local $0 = '/run';
    local $ENV{DEVELOPER_DASHBOARD_COMMAND} = '';
    is( Developer::Dashboard::Runtime::Result::_command_name(), 'dashboard', '_command_name falls back to dashboard when run-style paths have no usable parent name and env is empty' );
}
{
    local $ENV{RESULT} = '{"01-foo":{"stdout":"ok\\n","stderr":"","exit_code":0},"02-bar":{"stdout":"","stderr":"bad\\n","exit_code":1}}';
    my $report = decode_utf8( Developer::Dashboard::Runtime::Result::report( command => 'report-result' ) );
    like( $report, qr/report-result Run Report/, 'Runtime::Result report accepts an explicit command override' );
    like( $report, qr/01-foo/, 'Runtime::Result report lists successful hook names' );
    like( $report, qr/02-bar/, 'Runtime::Result report lists failing hook names' );
}

my $test_repos = tempdir( CLEANUP => 1 );
my $fake_bin = tempdir( CLEANUP => 1 );
my $cpanm_log = File::Spec->catfile( $fake_bin, 'cpanm.log' );
_write_file(
    File::Spec->catfile( $fake_bin, 'cpanm' ),
    <<"SH",
#!/bin/sh
printf '%s\\n' "\$*" >> "$cpanm_log"
if [ "\$DD_TEST_CPANM_FAIL" = "1" ]; then
  exit 1
fi
exit 0
SH
    0755,
);
local $ENV{PATH} = join ':', $fake_bin, ( $ENV{PATH} || () );

my $skill_paths = Developer::Dashboard::PathRegistry->new( home => File::Spec->catdir( $ENV{HOME}, 'skills-home' ) );
my $manager = Developer::Dashboard::SkillManager->new( paths => $skill_paths );
is_deeply( $manager->list, [], 'skill manager list is empty before installation' );
is( $manager->get_skill_path('missing'), undef, 'get_skill_path returns undef for missing skills' );
is( Developer::Dashboard::SkillManager::_extract_repo_name('bogus'), undef, '_extract_repo_name returns undef for strings without a repo path segment' );
is( Developer::Dashboard::SkillManager::_extract_repo_name('https://example.invalid/owner/repo.git'), 'repo', '_extract_repo_name strips .git from repository URLs' );
is( Developer::Dashboard::SkillManager::_extract_repo_name(''), undef, '_extract_repo_name returns undef for empty URLs' );
is_deeply( $manager->install(''), { error => 'Missing Git URL' }, 'install rejects an empty Git URL' );
like( $manager->install('https://example.invalid/not-a-repo.git')->{error}, qr/Failed to clone/, 'install reports git clone failures' );
is_deeply( $manager->update(''), { error => 'Missing repo name' }, 'update rejects an empty repo name' );
is_deeply( $manager->uninstall(''), { error => 'Missing repo name' }, 'uninstall rejects an empty repo name' );
is_deeply( $manager->update('missing-skill'), { error => "Skill 'missing-skill' not found" }, 'update rejects unknown skills' );
is_deeply( $manager->uninstall('missing-skill'), { error => "Skill 'missing-skill' not found" }, 'uninstall rejects unknown skills' );

my $dep_repo = _create_skill_repo( $test_repos, 'dep-skill', with_cpanfile => 1 );
my $install = $manager->install( 'file://' . $dep_repo );
ok( !$install->{error}, 'skill manager installs a skill with a cpanfile' ) or diag $install->{error};
my $duplicate = $manager->install( 'file://' . $dep_repo );
like( $duplicate->{error}, qr/already installed/, 'install rejects duplicate skill installs' );
my $dep_install = $manager->_install_skill_dependencies( $manager->get_skill_path('dep-skill') );
ok( !$dep_install->{error}, '_install_skill_dependencies succeeds for a skill with a cpanfile' ) or diag $dep_install->{error};
ok( -f $cpanm_log, '_install_skill_dependencies records an isolated cpanm invocation when the skill ships a cpanfile' );
my $metadata = $manager->list->[0];
is( $metadata->{has_config}, 1, 'skill metadata records config presence' );
is( $metadata->{has_cpanfile}, 1, 'skill metadata records cpanfile presence' );
is_deeply( $metadata->{docker_services}, ['postgres'], 'skill metadata records docker service folders' );
is_deeply( $metadata->{cli_commands}, ['run-test'], 'skill metadata records cli commands only, not hook directories' );
my $manual_skill_root = $skill_paths->skill_root('layout-skill');
make_path($manual_skill_root);
ok( $manager->_prepare_skill_layout($manual_skill_root), '_prepare_skill_layout succeeds for a partially populated skill root' );
ok( -f File::Spec->catfile( $manual_skill_root, 'config', 'config.json' ), '_prepare_skill_layout creates a missing config.json file' );

my $no_dep_repo = _create_skill_repo( $test_repos, 'no-dep-skill', with_cpanfile => 0 );
ok( !$manager->install( 'file://' . $no_dep_repo )->{error}, 'skill manager installs skills without a cpanfile' );
{
    local $ENV{DD_TEST_CPANM_FAIL} = 1;
    my $fail_repo = File::Spec->catdir( $test_repos, 'fail-dep-skill' );
    make_path($fail_repo);
    make_path( File::Spec->catdir( $fail_repo, 'local' ) );
    _write_file( File::Spec->catfile( $fail_repo, 'cpanfile' ), "requires 'JSON::XS';\n" );
    like(
        $manager->_install_skill_dependencies($fail_repo)->{error},
        qr/Failed to install skill dependencies/,
        'install reports isolated dependency installation failures',
    );
}
{
    my $broken_repo = _create_skill_repo( $test_repos, 'broken-update-skill', with_cpanfile => 0 );
    ok( !$manager->install( 'file://' . $broken_repo )->{error}, 'broken-update-skill installs cleanly' );
    my $installed_root = $manager->get_skill_path('broken-update-skill');
    _run_or_die( 'git', '-C', $installed_root, 'remote', 'set-url', 'origin', 'file:///definitely-missing-repo-path' );
    like(
        $manager->update('broken-update-skill')->{error},
        qr/Failed to update skill:/,
        'update reports git pull failures',
    );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::SkillManager::remove_tree = sub {
        my ( $path, $options ) = @_;
        push @{ ${ $options->{error} } }, { $path => 'boom' };
        return;
    };
    like(
        $manager->uninstall('no-dep-skill')->{error},
        qr/Failed to uninstall skill:/,
        'uninstall reports remove_tree failures',
    );
}

my $dispatcher = Developer::Dashboard::SkillDispatcher->new( paths => $skill_paths );
is_deeply( $dispatcher->dispatch( '', 'run-test' ), { error => 'Missing skill name' }, 'dispatcher rejects missing skill names' );
is_deeply( $dispatcher->dispatch( 'dep-skill', '' ), { error => 'Missing command name' }, 'dispatcher rejects missing command names' );
is_deeply(
    $dispatcher->dispatch( 'missing-skill', 'run-test' ),
    { error => "Skill 'missing-skill' not found" },
    'dispatcher rejects missing skills',
);
is_deeply( $dispatcher->execute_hooks( '', 'run-test' ), { hooks => {}, result_state => {} }, 'execute_hooks returns an empty result for missing skill names' );
is_deeply( $dispatcher->execute_hooks( 'dep-skill', '' ), { hooks => {}, result_state => {} }, 'execute_hooks returns an empty result for missing command names' );
is_deeply( $dispatcher->execute_hooks( 'missing-skill', 'run-test' ), { hooks => {}, result_state => {} }, 'execute_hooks returns an empty result for missing skills' );
my $hookless_repo = _create_skill_repo( $test_repos, 'hookless-skill', with_hook => 0, with_cpanfile => 0 );
ok( !$manager->install( 'file://' . $hookless_repo )->{error}, 'hookless skill installs cleanly' );
is_deeply( $dispatcher->execute_hooks( 'hookless-skill', 'run-test' ), { hooks => {}, result_state => {} }, 'execute_hooks returns an empty result when no hook directory exists' );
is_deeply( $dispatcher->get_skill_config(''), {}, 'get_skill_config returns an empty hash for empty skill names' );
is_deeply( $dispatcher->get_skill_config('missing-skill'), {}, 'get_skill_config returns an empty hash for missing skills' );
my $invalid_config_root = $manager->get_skill_path('hookless-skill');
_write_file( File::Spec->catfile( $invalid_config_root, 'config', 'config.json' ), "{not json}\n" );
is_deeply( $dispatcher->get_skill_config('hookless-skill'), {}, 'get_skill_config falls back to an empty hash for invalid JSON config' );
is( $dispatcher->get_skill_path(''), undef, 'get_skill_path returns undef for empty skill names' );
is( $dispatcher->get_skill_path('dep-skill'), $manager->get_skill_path('dep-skill'), 'get_skill_path returns the installed skill path for valid skills' );
is( $dispatcher->command_path( '', 'run-test' ), undef, 'command_path returns undef for missing skill names' );
is( $dispatcher->command_path( 'dep-skill', '' ), undef, 'command_path returns undef for missing command names' );
is( $dispatcher->command_path( 'dep-skill', 'missing' ), undef, 'command_path returns undef for missing skill commands' );
my $no_bookmark_repo = _create_skill_repo( $test_repos, 'no-bookmarks-skill', with_cpanfile => 0, with_bookmark => 0 );
ok( !$manager->install( 'file://' . $no_bookmark_repo )->{error}, 'skill without bookmarks installs cleanly' );
is( $dispatcher->route_response( skill_name => 'missing-skill', route => 'bookmarks' )->[0], 404, 'route_response returns 404 for missing skills' );
is( $dispatcher->route_response( skill_name => 'dep-skill', route => '' )->[0], 404, 'route_response returns 404 for empty routes' );
is( $dispatcher->route_response( skill_name => 'no-bookmarks-skill', route => 'bookmarks' )->[0], 404, 'route_response returns 404 when a skill has no bookmarks' );
is( $dispatcher->route_response( skill_name => 'dep-skill', route => 'unknown' )->[0], 404, 'route_response rejects unsupported skill routes' );
{
    my $local_lib = File::Spec->catdir( $manager->get_skill_path('dep-skill'), 'local', 'lib', 'perl5' );
    make_path($local_lib);
    local $ENV{PERL5LIB} = 'base-lib';
    my %env = $dispatcher->_skill_env(
        skill_name   => 'dep-skill',
        skill_path   => $manager->get_skill_path('dep-skill'),
        command      => 'run-test',
        result_state => { alpha => { stdout => "ok\n" } },
    );
    like( $env{PERL5LIB}, qr/\Q$local_lib\E/, '_skill_env prepends the skill-local perl library when present' );
    like( $env{RESULT}, qr/alpha/, '_skill_env serializes RESULT state for skill hooks and commands' );
}

done_testing();

sub _create_skill_repo {
    my ( $root, $name, %args ) = @_;
    my $repo = File::Spec->catdir( $root, $name );
    make_path($repo);
    my $cwd = getcwd();
    chdir $repo or die "Unable to chdir to $repo: $!";
    _run_or_die(qw(git init --quiet));
    _run_or_die(qw(git config user.email test@example.com));
    _run_or_die(qw(git config user.name Test));

    make_path('cli');
    make_path('config');
    make_path( File::Spec->catdir( 'config', 'docker', 'postgres' ) );
    make_path('state');
    make_path('logs');
    make_path('dashboards') if !exists $args{with_bookmark} || $args{with_bookmark};
    if ( !exists $args{with_hook} || $args{with_hook} ) {
        make_path( File::Spec->catdir( 'cli', 'run-test.d' ) );
    }

    _write_file(
        File::Spec->catfile( 'cli', 'run-test' ),
        "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nprint join('|', \@ARGV), qq{\\n};\n",
        0755,
    );
    if ( !exists $args{with_hook} || $args{with_hook} ) {
        _write_file(
            File::Spec->catfile( 'cli', 'run-test.d', '00-pre.pl' ),
            "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nprint qq{hooked\\n};\n",
            0755,
        );
    }
    _write_file( File::Spec->catfile( 'config', 'config.json' ), qq|{"skill_name":"$name"}\n| );
    _write_file( File::Spec->catfile( 'config', 'docker', 'postgres', 'compose.yml' ), "services: {}\n" );
    if ( !exists $args{with_cpanfile} || $args{with_cpanfile} ) {
        _write_file( 'cpanfile', "requires 'JSON::XS';\n" );
    }
    if ( !exists $args{with_bookmark} || $args{with_bookmark} ) {
        _write_file(
            File::Spec->catfile( 'dashboards', 'welcome' ),
            "TITLE: Welcome\n:--------------------------------------------------------------------------------:\nBOOKMARK: welcome\n:--------------------------------------------------------------------------------:\nHTML:\nHello\n",
        );
    }

    _run_or_die(qw(git add .));
    _run_or_die( 'git', 'commit', '-m', "Initial $name" );
    chdir $cwd or die "Unable to chdir back to $cwd: $!";
    return $repo;
}

sub _run_or_die {
    my (@command) = @_;
    my ( $stdout, $stderr, $exit ) = capture {
        system(@command);
    };
    die "Command failed: @command\n$stderr" if $exit != 0;
    return $stdout;
}

sub _write_file {
    my ( $path, $content, $mode ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content;
    close $fh;
    chmod( $mode || 0644, $path ) or die "Unable to chmod $path: $!";
    return 1;
}

sub _dies {
    my ($code) = @_;
    my $error = eval { $code->(); 1 } ? '' : $@;
    return $error;
}

__END__

=head1 NAME

21-refactor-coverage.t - direct coverage closure for helper packaging and skills

=head1 DESCRIPTION

This test closes direct branch coverage for the private helper packaging,
query parsing, runtime result, path registry, and isolated skill modules.

=cut
