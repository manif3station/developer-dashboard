use strict;
use warnings;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::CLI::OpenFileGrep qw(grep_matching_files native_grep_usage);

# _spec(@argv)
# Parses one grep argument vector into a native search specification.
# Dies propagate, so wrap the call in eval where a die is expected.
sub _spec {
    my (@argv) = @_;
    return Developer::Dashboard::CLI::OpenFileGrep::_parse_native_grep_args( \@argv );
}

# _handle_lines($spec, $content)
# Searches one scalar's content through _native_grep_handle and returns
# the matching "display:line:content" lines.
sub _handle_lines {
    my ( $spec, $content ) = @_;
    open my $fh, '<', \$content or die "open scalar handle: $!";
    return Developer::Dashboard::CLI::OpenFileGrep::_native_grep_handle( $spec, $fh, 'display' );
}

# _write_file($dir, $name, $content)
# Writes one file into a temp tree and returns its path.
sub _write_file {
    my ( $dir, $name, $content ) = @_;
    my $path = File::Spec->catfile( $dir, $name );
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $content;
    close $fh or die "close $path: $!";
    return $path;
}

# _try_symlink($target, $link)
# Creates a symlink, returning true when it worked. Symlink creation
# needs privileges on some Windows boxes, so callers skip when it fails.
sub _try_symlink {
    my ( $target, $link ) = @_;
    my $ok = eval { symlink $target, $link; 1 };
    return $ok ? 1 : 0;
}

# _with_fake_grep($code)
# Runs $code with a fake grep first on PATH: a script that exits 1
# whatever it is asked, so grep_matching_files sees exit 1 deterministically.
# On Windows the fake is grep.bat (found through PATHEXT); elsewhere it is grep.
sub _with_fake_grep {
    my ($code) = @_;
    my $dir  = tempdir( CLEANUP => 1 );
    my $name = $^O eq 'MSWin32' ? 'grep.bat' : 'grep';
    my $path = File::Spec->catfile( $dir, $name );
    open my $fh, '>', $path or die "write fake grep: $!";
    if ( $^O eq 'MSWin32' ) {
        print {$fh} "\@echo off\n";
        print {$fh} "exit /b 1\n";
    }
    else {
        print {$fh} "#!/bin/sh\nexit 1\n";
    }
    close $fh or die "close fake grep: $!";
    chmod 0755, $path or die "chmod fake grep: $!";
    local $ENV{PATH} = $dir . ( $^O eq 'MSWin32' ? ';' : ':' ) . $ENV{PATH};
    return $code->();
}

# _with_no_grep($code)
# Runs $code with the dispatch gate mocked to "grep absent on Windows":
# command_in_path finds nothing and is_real_windows is true. The mocks
# are localised to the OpenFileGrep package, so they only apply inside $code.
sub _with_no_grep {
    my ($code) = @_;
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::OpenFileGrep::command_in_path = sub { 0 };
    local *Developer::Dashboard::CLI::OpenFileGrep::is_real_windows = sub { 1 };
    return $code->();
}

# native_grep_usage: the fallback usage text.
{
    my $usage = native_grep_usage();
    like( $usage, qr/\AUsage: grep /, 'usage: starts with "Usage: grep"' );
    like( $usage, qr/\n\z/, 'usage: ends with a newline' );
    like( $usage, qr/-r\/-R/, 'usage: lists -r/-R' );
    like( $usage, qr/-i/, 'usage: lists -i' );
    like( $usage, qr/-F/, 'usage: lists -F' );
    like( $usage, qr/-d/, 'usage: lists -d' );
}

# _parse_native_grep_args: flags and operands.
{
    my $spec = _spec( 'needle', 'file.txt' );
    is_deeply( $spec->{patterns}, ['needle'], 'parse: positional pattern' );
    is_deeply( $spec->{paths},    ['file.txt'], 'parse: positional path' );
    is( $spec->{ignore_case}, 0, 'parse: ignore_case off by default' );
    is( $spec->{invert},      0, 'parse: invert off by default' );
    ok( defined $spec->{regex}, 'parse: regex compiled' );
    ok( 'a needle here' =~ $spec->{regex}, 'parse: regex matches the pattern' );
    ok( !( 'nothing here' =~ $spec->{regex} ), 'parse: regex does not match other text' );
}
{
    my $spec = _spec( '-i', 'Needle', 'file.txt' );
    is( $spec->{ignore_case}, 1, 'parse: -i sets ignore_case' );
    ok( 'NEEDLE' =~ $spec->{regex}, 'parse: -i regex matches other case' );
}
{
    my $spec = _spec( '--ignore-case', 'Needle', 'file.txt' );
    is( $spec->{ignore_case}, 1, 'parse: --ignore-case sets ignore_case' );
}
{
    my $spec = _spec( '-v', 'needle', 'file.txt' );
    is( $spec->{invert}, 1, 'parse: -v sets invert' );
}
{
    my $spec = _spec( '--invert-match', 'needle', 'file.txt' );
    is( $spec->{invert}, 1, 'parse: --invert-match sets invert' );
}
{
    my $spec = _spec( '-w', 'foo', 'file.txt' );
    is( $spec->{word}, 1, 'parse: -w sets word' );
    ok( 'a foo b' =~ $spec->{regex}, 'parse: -w regex matches the whole word' );
    ok( !( 'foobar' =~ $spec->{regex} ), 'parse: -w regex does not match inside a word' );
}
{
    my $spec = _spec( '--word-regexp', 'foo', 'file.txt' );
    is( $spec->{word}, 1, 'parse: --word-regexp sets word' );
}
{
    my $spec = _spec( '-x', 'foo', 'file.txt' );
    is( $spec->{line_regexp}, 1, 'parse: -x sets line_regexp' );
    ok( 'foo' =~ $spec->{regex}, 'parse: -x regex matches the whole line' );
    ok( !( 'foo bar' =~ $spec->{regex} ), 'parse: -x regex does not match a longer line' );
}
{
    my $spec = _spec( '--line-regexp', 'foo', 'file.txt' );
    is( $spec->{line_regexp}, 1, 'parse: --line-regexp sets line_regexp' );
}
{
    my $spec = _spec( '-F', 'a+b', 'file.txt' );
    is( $spec->{fixed}, 1, 'parse: -F sets fixed' );
    ok( 'a+b' =~ $spec->{regex}, 'parse: -F regex matches the literal string' );
    ok( !( 'aab' =~ $spec->{regex} ), 'parse: -F regex does not treat + as a quantifier' );
}
{
    my $spec = _spec( '--fixed-strings', 'a+b', 'file.txt' );
    is( $spec->{fixed}, 1, 'parse: --fixed-strings sets fixed' );
}
{
    my $spec = _spec( '-E', 'a+', 'file.txt' );
    ok( 'aaa' =~ $spec->{regex}, 'parse: -E is accepted and the pattern still applies' );
}
{
    my $spec = _spec( '--extended-regexp', 'a+', 'file.txt' );
    ok( 'aaa' =~ $spec->{regex}, 'parse: --extended-regexp is accepted' );
}
{
    my $spec = _spec( '-n', '-H', '-s', '-I', 'needle', 'file.txt' );
    is_deeply( $spec->{patterns}, ['needle'], 'parse: -n -H -s -I are accepted and ignored' );
    is_deeply( $spec->{paths},    ['file.txt'], 'parse: paths follow the ignored flags' );
}
{
    my $spec = _spec( '--line-number', '--with-filename', '--no-messages', 'needle', 'file.txt' );
    is_deeply( $spec->{patterns}, ['needle'], 'parse: --line-number --with-filename --no-messages are accepted and ignored' );
}
{
    my $spec = _spec( '-q', 'needle', 'file.txt' );
    is( $spec->{quiet}, 1, 'parse: -q sets quiet' );
}
{
    my $spec = _spec( '--quiet', 'needle', 'file.txt' );
    is( $spec->{quiet}, 1, 'parse: --quiet sets quiet' );
}
{
    my $spec = _spec( '--silent', 'needle', 'file.txt' );
    is( $spec->{quiet}, 1, 'parse: --silent sets quiet' );
}
{
    my $spec = _spec( '-a', 'needle', 'file.txt' );
    is( $spec->{text}, 1, 'parse: -a sets text' );
}
{
    my $spec = _spec( '--text', 'needle', 'file.txt' );
    is( $spec->{text}, 1, 'parse: --text sets text' );
}

# _parse_native_grep_args: recursion, directories and binary files.
{
    my $spec = _spec( '-r', 'needle', 'dir' );
    is( $spec->{directories}, 'recurse', 'parse: -r sets directories to recurse' );
    is( $spec->{recursive_follow}, 0, 'parse: -r does not follow symlinked directories' );
}
{
    my $spec = _spec( '-R', 'needle', 'dir' );
    is( $spec->{directories}, 'recurse', 'parse: -R sets directories to recurse' );
    is( $spec->{recursive_follow}, 1, 'parse: -R follows symlinked directories' );
}
{
    my $spec = _spec( '--recursive', 'needle', 'dir' );
    is( $spec->{directories}, 'recurse', 'parse: --recursive sets directories to recurse' );
    is( $spec->{recursive_follow}, 0, 'parse: --recursive does not follow symlinked directories' );
}
{
    my $spec = _spec( '-d', 'skip', 'needle', 'dir' );
    is( $spec->{directories}, 'skip', 'parse: -d skip sets directories to skip' );
}
{
    my $spec = _spec( '-dskip', 'needle', 'dir' );
    is( $spec->{directories}, 'skip', 'parse: -dskip sets directories to skip' );
}
{
    my $spec = _spec( '--directories=skip', 'needle', 'dir' );
    is( $spec->{directories}, 'skip', 'parse: --directories=skip sets directories to skip' );
}
{
    my $spec = _spec( '--directories', 'read', 'needle', 'dir' );
    is( $spec->{directories}, 'read', 'parse: --directories read sets directories to read' );
}
{
    my $spec = _spec( '-d', 'skip', '-r', 'needle', 'dir' );
    is( $spec->{directories}, 'recurse', 'parse: -d skip then -r recurses (last one wins)' );
}
{
    my $spec = _spec( '-r', '-d', 'skip', 'needle', 'dir' );
    is( $spec->{directories}, 'skip', 'parse: -r then -d skip skips (last one wins)' );
}
{
    my $spec = _spec( '--binary-files=text', 'needle', 'file.txt' );
    is( $spec->{text}, 1, 'parse: --binary-files=text sets text' );
}
{
    my $spec = _spec( '--binary-files', 'binary', 'needle', 'file.txt' );
    is( $spec->{text}, 0, 'parse: --binary-files=binary does not set text' );
}
{
    my $spec = _spec( '--binary-files', 'without-match', 'needle', 'file.txt' );
    is( $spec->{text}, 0, 'parse: --binary-files=without-match does not set text' );
}

# _parse_native_grep_args: patterns via -e and --regexp.
{
    my $spec = _spec( '-e', 'foo', 'file.txt' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: -e takes the next argument as the pattern' );
    is_deeply( $spec->{paths}, ['file.txt'], 'parse: the path follows -e' );
}
{
    my $spec = _spec( '-efoo', 'file.txt' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: -efoo takes the attached pattern' );
}
{
    my $spec = _spec( '--regexp=foo', 'file.txt' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: --regexp=foo takes the pattern' );
}
{
    my $spec = _spec( '--regexp', 'foo', 'file.txt' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: --regexp takes the next argument as the pattern' );
}
{
    my $spec = _spec( '-e', 'foo', '-e', 'bar', 'file.txt' );
    is_deeply( $spec->{patterns}, [ 'foo', 'bar' ], 'parse: two -e options give two patterns' );
    ok( 'bar' =~ $spec->{regex}, 'parse: the combined regex matches the second pattern' );
    ok( 'foo' =~ $spec->{regex}, 'parse: the combined regex matches the first pattern' );
}
{
    my $spec = _spec( '-ie', 'foo', 'file.txt' );
    is( $spec->{ignore_case}, 1, 'parse: bundled -ie sets ignore_case' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: bundled -ie takes the attached pattern' );
}

# _parse_native_grep_args: positional handling and the -- terminator.
{
    my $spec = _spec( 'foo', '-i' );
    is_deeply( $spec->{patterns}, ['foo'], 'parse: the first positional is the pattern' );
    is_deeply( $spec->{paths}, ['-i'], 'parse: options after the pattern are paths, not flags' );
}
{
    my $spec = _spec( '--', '-i', 'file.txt' );
    is_deeply( $spec->{patterns}, ['-i'], 'parse: -- makes the next argument the pattern even when it starts with -' );
    is_deeply( $spec->{paths}, ['file.txt'], 'parse: the path follows --' );
}
{
    my $spec = _spec( 'foo', 'a.txt', 'b.txt' );
    is_deeply( $spec->{paths}, [ 'a.txt', 'b.txt' ], 'parse: several positional paths are kept in order' );
}

# _parse_native_grep_args: long options that take no value die when given one.
for my $name ( qw(recursive ignore-case invert-match word-regexp line-regexp fixed-strings extended-regexp line-number with-filename no-messages quiet silent text) ) {
    my $ok = eval { _spec( "--$name=x", 'foo', 'file.txt' ); 1 };
    my $error = $@;
    ok( !$ok, "parse: --$name=x dies" );
    like( $error, qr/does not take a value/, "parse: --$name=x names the value problem" );
}

# _parse_native_grep_args: unsupported options, missing values, no pattern, invalid pattern.
{
    my $ok = eval { _spec( '--bogus', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an unsupported long option dies' );
    like( $@, qr/unsupported grep option '--bogus'/, 'parse: the unsupported long option is named' );
}
{
    my $ok = eval { _spec( '--1bad', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: a malformed long option dies' );
    like( $@, qr/unsupported grep option '--1bad'/, 'parse: the malformed long option is named' );
}
{
    my $ok = eval { _spec( '-Z', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an unsupported short option dies' );
    like( $@, qr/unsupported grep option '-Z'/, 'parse: the unsupported short option is named' );
}
{
    my $ok = eval { _spec( '-iZ', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an unsupported option in a bundle dies' );
    like( $@, qr/unsupported grep option '-Z'/, 'parse: the unsupported bundled option is named' );
}
{
    my $ok = eval { _spec('-e'); 1 };
    ok( !$ok, 'parse: -e with no pattern dies' );
    like( $@, qr/option '-e' requires a pattern/, 'parse: -e names the missing pattern' );
}
{
    my $ok = eval { _spec('-d'); 1 };
    ok( !$ok, 'parse: -d with no value dies' );
    like( $@, qr/option '-d' requires a value/, 'parse: -d names the missing value' );
}
{
    my $ok = eval { _spec('--regexp'); 1 };
    ok( !$ok, 'parse: --regexp with no pattern dies' );
    like( $@, qr/option '--regexp' requires a pattern/, 'parse: --regexp names the missing pattern' );
}
{
    my $ok = eval { _spec('--directories'); 1 };
    ok( !$ok, 'parse: --directories with no value dies' );
    like( $@, qr/option '--directories' requires a value/, 'parse: --directories names the missing value' );
}
{
    my $ok = eval { _spec('--binary-files'); 1 };
    ok( !$ok, 'parse: --binary-files with no value dies' );
    like( $@, qr/option '--binary-files' requires a value/, 'parse: --binary-files names the missing value' );
}
{
    my $ok = eval { _spec( '--binary-files=bogus', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an unsupported --binary-files mode dies' );
    like( $@, qr/unsupported --binary-files mode 'bogus'/, 'parse: the unsupported mode is named' );
}
{
    my $ok = eval { _spec( '-d', 'bogus', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an unsupported -d mode dies' );
    like( $@, qr/unsupported --directories mode 'bogus'/, 'parse: the unsupported -d mode is named' );
}
{
    my $ok = eval { _spec(); 1 };
    ok( !$ok, 'parse: no arguments dies' );
    like( $@, qr/no search pattern given/, 'parse: no arguments names the missing pattern' );
}
{
    my $ok = eval { _spec('-i'); 1 };
    ok( !$ok, 'parse: options only, no pattern, dies' );
    like( $@, qr/no search pattern given/, 'parse: options only names the missing pattern' );
}
{
    my $ok = eval { _spec( '[', 'file.txt' ); 1 };
    ok( !$ok, 'parse: an invalid pattern dies' );
    like( $@, qr/invalid search pattern/, 'parse: the invalid pattern is named' );
}

# _native_grep_set_directories, called directly.
{
    my $spec = _spec( 'needle', 'file.txt' );
    Developer::Dashboard::CLI::OpenFileGrep::_native_grep_set_directories( $spec, 'read' );
    is( $spec->{directories}, 'read', 'set_directories: read is accepted' );
    Developer::Dashboard::CLI::OpenFileGrep::_native_grep_set_directories( $spec, 'skip' );
    is( $spec->{directories}, 'skip', 'set_directories: skip is accepted' );
    Developer::Dashboard::CLI::OpenFileGrep::_native_grep_set_directories( $spec, 'recurse' );
    is( $spec->{directories}, 'recurse', 'set_directories: recurse is accepted' );
    my $ok = eval { Developer::Dashboard::CLI::OpenFileGrep::_native_grep_set_directories( $spec, 'bogus' ); 1 };
    ok( !$ok, 'set_directories: an unsupported mode dies' );
    like( $@, qr/unsupported --directories mode 'bogus'/, 'set_directories: the unsupported mode is named' );
    is( $spec->{directories}, 'recurse', 'set_directories: a failed set leaves the previous mode' );
}

# _native_grep_handle, called directly on scalar content.
{
    my $content = "first needle line\nsecond line\nthird needle here\n";
    my $spec    = _spec( 'needle', 'file.txt' );
    my @lines   = _handle_lines( $spec, $content );
    is_deeply( \@lines, [ 'display:1:first needle line', 'display:3:third needle here' ], 'handle: matching lines come back as display:line:content' );
}
{
    my $spec  = _spec( 'zzz', 'file.txt' );
    my @lines = _handle_lines( $spec, "first needle line\nsecond line\n" );
    is_deeply( \@lines, [], 'handle: no match gives no lines' );
}
{
    my $spec  = _spec( '-v', 'needle', 'file.txt' );
    my @lines = _handle_lines( $spec, "first needle line\nsecond line\nthird needle here\n" );
    is_deeply( \@lines, ['display:2:second line'], 'handle: -v returns the lines that do not match' );
}
{
    my $spec  = _spec( '-q', 'needle', 'file.txt' );
    my @lines = _handle_lines( $spec, "first needle line\nsecond line\n" );
    is_deeply( \@lines, [], 'handle: -q suppresses the matching lines' );
}
{
    my $spec  = _spec( '-i', 'NEEDLE', 'file.txt' );
    my @lines = _handle_lines( $spec, "first needle line\nthird needle here\n" );
    is( scalar @lines, 2, 'handle: -i matches regardless of case' );
}
{
    # A NUL byte anywhere marks the file binary, so the file contributes
    # nothing: the return is empty even though a line matched before it.
    my $spec  = _spec( 'match', 'file.txt' );
    my @lines = _handle_lines( $spec, "match one\nbin\0ary\nmatch two\n" );
    is_deeply( \@lines, [], 'handle: a NUL byte anywhere makes the file contribute nothing' );
}
{
    my $spec  = _spec( 'match', 'file.txt' );
    my @lines = _handle_lines( $spec, "bin\0ary\nmatch one\n" );
    is_deeply( \@lines, [], 'handle: a NUL byte on the first line gives no lines' );
}
{
    my $spec  = _spec( '-a', 'match', 'file.txt' );
    my @lines = _handle_lines( $spec, "match one\nbin\0ary\nmatch two\n" );
    is_deeply( \@lines, [ 'display:1:match one', 'display:3:match two' ], 'handle: -a searches binary content as text' );
}
{
    my $spec  = _spec( 'foo', 'file.txt' );
    my @lines = _handle_lines( $spec, "foo\r\nbar\n" );
    is_deeply( \@lines, ["display:1:foo\r"], 'handle: a trailing carriage return survives in the content' );
}
{
    my $spec  = _spec( '-x', 'foo', 'file.txt' );
    my @lines = _handle_lines( $spec, "foo\nfoo bar\n" );
    is_deeply( \@lines, ['display:1:foo'], 'handle: -x matches only the whole line' );
}

# A temp tree for the file, path, directory and output tests.
my $root = tempdir( CLEANUP => 1 );
my $one  = _write_file( $root, 'one.txt', "alpha needle\nbeta\n" );
my $two  = _write_file( $root, 'two.txt', "gamma\nneedle delta\n" );
my $sub  = File::Spec->catdir( $root, 'sub' );
mkdir $sub or die "mkdir $sub: $!";
my $deep = _write_file( $sub, 'deep.txt', "needle deep\n" );

# _native_grep_file, called directly.
{
    my $spec  = _spec( 'needle', $one );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_file( $spec, $one, $one );
    is_deeply( \@lines, [ "$one:1:alpha needle" ], 'file: a match comes back under the file path' );
}
{
    my $spec  = _spec( 'needle', $one );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_file( $spec, $one, 'shown.txt' );
    is_deeply( \@lines, ['shown.txt:1:alpha needle'], 'file: the display path is used, not the real path' );
}
{
    my $spec  = _spec( 'zzz', $one );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_file( $spec, $one, $one );
    is_deeply( \@lines, [], 'file: no match gives no lines' );
    is_deeply( $spec->{errors}, [], 'file: no match records no error' );
}
{
    my $missing = File::Spec->catfile( $root, 'missing.txt' );
    my $spec    = _spec( 'needle', $missing );
    my @lines   = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_file( $spec, $missing, $missing );
    is_deeply( \@lines, [], 'file: an unopenable file gives no lines' );
    is( scalar @{ $spec->{errors} }, 1, 'file: an unopenable file records one error' );
    like( $spec->{errors}[0], qr/\Q$missing\E/, 'file: the error names the file' );
}

# _native_grep_path, called directly.
{
    my $spec  = _spec( 'needle', $one );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, $one );
    is_deeply( \@lines, [ "$one:1:alpha needle" ], 'path: a regular file is searched' );
}
{
    my $spec  = _spec( 'needle', $root );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, $root );
    is_deeply( \@lines, [], 'path: a directory without recursion gives no lines' );
    is( scalar @{ $spec->{errors} }, 1, 'path: a directory without recursion records one error' );
    like( $spec->{errors}[0], qr/Is a directory/, 'path: the directory error says it is a directory' );
}
{
    my $spec  = _spec( '-d', 'skip', 'needle', $root );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, $root );
    is_deeply( \@lines, [], 'path: -d skip silences a directory' );
    is_deeply( $spec->{errors}, [], 'path: -d skip records no error' );
}
{
    my $spec  = _spec( '-r', 'needle', $root );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, $root );
    is( scalar @lines, 3, 'path: -r recurses into a directory and its subdirectory' );
    ok( ( grep { $_ eq "$one:1:alpha needle" } @lines ), 'path: -r finds the match in the first file' );
    ok( ( grep { $_ eq "$two:2:needle delta" } @lines ), 'path: -r finds the match in the second file' );
    ok( ( grep { $_ eq "$deep:1:needle deep" } @lines ), 'path: -r finds the match in the subdirectory' );
}
{
    my $missing = File::Spec->catfile( $root, 'missing.txt' );
    my $spec    = _spec( 'needle', $missing );
    my @lines   = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, $missing );
    is_deeply( \@lines, [], 'path: a missing path gives no lines' );
    is( scalar @{ $spec->{errors} }, 1, 'path: a missing path records one error' );
    like( $spec->{errors}[0], qr/No such file or directory/, 'path: the missing-path error names the problem' );
}
{
    # '-' reads standard input.
    my $spec = _spec('needle');
    open my $in, '<', \"alpha needle\nbeta\n" or die "open scalar: $!";
    local *STDIN = $in;
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_path( $spec, '-' );
    is_deeply( \@lines, ['(standard input):1:alpha needle'], 'path: - reads standard input' );
}

# _native_grep_dir, called directly.
{
    my $spec  = _spec( '-r', 'needle', $root );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $root, [] );
    ok( ( grep { $_ eq "$deep:1:needle deep" } @lines ), 'dir: recursion finds a match in a subdirectory' );
    ok( ( grep { $_ eq "$one:1:alpha needle" } @lines ), 'dir: recursion finds a match at the top' );
    is_deeply( $spec->{errors}, [], 'dir: a clean tree records no errors' );
}
{
    # Symlinked files are searched; symlinked directories are followed only with -R.
    my $target    = _write_file( $root, 'target.txt', "needle target\n" );
    my $link_file = File::Spec->catfile( $root, 'link.txt' );
    my $link_dir  = File::Spec->catdir( $root, 'linkdir' );
    SKIP: {
        skip 'symlinks need privileges on this box', 4
          if !_try_symlink( $target, $link_file ) || !_try_symlink( $sub, $link_dir );
        my $spec_r = _spec( '-r', 'needle', $root );
        my @lines_r = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec_r, $root, [] );
        ok( ( grep { $_ eq "$link_file:1:needle target" } @lines_r ), 'dir: -r searches a symlinked file' );
        ok( !( grep { $_ =~ /\Q$link_dir\E/ } @lines_r ), 'dir: -r does not follow a symlinked directory' );
        my $spec_R = _spec( '-R', 'needle', $root );
        my @lines_R = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec_R, $root, [] );
        ok( ( grep { $_ =~ /\Q$link_dir\E/ } @lines_R ), 'dir: -R follows a symlinked directory' );
        ok( ( grep { $_ eq "$link_file:1:needle target" } @lines_R ), 'dir: -R still searches a symlinked file' );
    }
}
{
    # A symlink cycle cannot recurse forever: link a directory back to its own ancestor.
    SKIP: {
        my $cycle = File::Spec->catdir( $sub, 'cycle' );
        skip 'symlinks need privileges on this box', 1 if !_try_symlink( $root, $cycle );
        my $spec  = _spec( '-R', 'needle', $root );
        my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $root, [] );
        ok( ( grep { $_ eq "$deep:1:needle deep" } @lines ), 'dir: a symlink cycle still returns the real matches' );
    }
}
{
    # An unreadable directory records a file error and contributes no lines.
    SKIP: {
        skip 'unreadable directories cannot be made on Windows or as root', 3
          if $^O eq 'MSWin32' || $> == 0;
        my $closed = File::Spec->catdir( $root, 'closed' );
        mkdir $closed or die "mkdir $closed: $!";
        _write_file( $closed, 'hidden.txt', "needle hidden\n" );
        chmod 0000, $closed or die "chmod $closed: $!";
        my $spec  = _spec( '-r', 'needle', $root );
        my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $root, [] );
        ok( !( grep { /hidden/ } @lines ), 'dir: an unreadable directory contributes no lines' );
        is( scalar @{ $spec->{errors} }, 1, 'dir: an unreadable directory records one error' );
        like( $spec->{errors}[0], qr/\Q$closed\E/, 'dir: the error names the unreadable directory' );
        chmod 0755, $closed or die "chmod back $closed: $!";
    }
}

# _native_grep_output, called directly.
{
    my $out = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ 'needle', $one ] );
    is( $out, "$one:1:alpha needle\n", 'output: one match returns one file:line:content line with a trailing newline' );
}
{
    my $out = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ 'zzz', $one ] );
    is( $out, '', 'output: no match returns the empty string' );
}
{
    my $out = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ '-q', 'needle', $one ] );
    is( $out, '', 'output: -q returns the empty string even when there are matches' );
}
{
    my $out = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ 'needle', $one, $two ] );
    is( $out, "$one:1:alpha needle\n$two:2:needle delta\n", 'output: matches from several files are joined in order' );
}
{
    # No paths: reads standard input.
    open my $in, '<', \"alpha needle\nbeta\n" or die "open scalar: $!";
    local *STDIN = $in;
    my $out = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( ['needle'] );
    is( $out, "(standard input):1:alpha needle\n", 'output: with no paths the search reads standard input' );
}
{
    # File errors dominate matches: the search runs to completion and the first error is reported.
    my $missing = File::Spec->catfile( $root, 'missing.txt' );
    my $ok = eval { Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ 'needle', $one, $missing ] ); 1 };
    ok( !$ok, 'output: a missing file dies even when another file matched' );
    like( $@, qr/\Q$missing\E/, 'output: the die names the missing file' );
    like( $@, qr/No such file or directory/, 'output: the die names the problem' );
}
{
    my $ok = eval { Developer::Dashboard::CLI::OpenFileGrep::_native_grep_output( [ '--bogus', 'needle', $one ] ); 1 };
    ok( !$ok, 'output: an unsupported option dies' );
    like( $@, qr/unsupported grep option '--bogus'/, 'output: the die names the option' );
}

# grep_matching_files with grep absent (AC 2): a fake grep that exits 1,
# is_real_windows mocked true, command_in_path mocked to find nothing.
# The dispatch gate opens and the native fallback runs on every leg.
{
    my @found = _with_fake_grep(
        sub {
            _with_no_grep( sub { grep_matching_files( args => [ 'needle', $one ] ) } );
        }
    );
    # With is_real_windows mocked true, the R120 normalisation applies:
    # returned paths use the native separator, so '/' becomes '\'.
    my $expected = $one;
    $expected =~ s{/}{\\}g;
    is_deeply( \@found, [$expected], 'grep absent: the native fallback returns the matching file' );
    my @none = _with_fake_grep(
        sub {
            _with_no_grep( sub { grep_matching_files( args => [ 'zzz-no-match', $one ] ) } );
        }
    );
    is_deeply( \@none, [], 'grep absent: the native fallback returns an empty list when nothing matches' );
}
{
    # Control: with the real grep present and no mocks, the same call returns the same file.
    my @found = grep_matching_files( args => [ 'needle', $one ] );
    is_deeply( \@found, [$one], 'control: system grep returns the matching file' );
}
{
    my $ok = eval { grep_matching_files( args => 'needle' ); 1 };
    ok( !$ok, 'grep_matching_files: non-array args die' );
    like( $@, qr/grep args must be an array reference/, 'grep_matching_files: the die names the bad args' );
}
{
    my $ok = eval { grep_matching_files( args => [] ); 1 };
    ok( !$ok, 'grep_matching_files: empty args die with usage' );
    like( $@, qr/Usage: d2 of grep/, 'grep_matching_files: the die is the usage text' );
}

# Extra coverage for the shared decoder and the directory walk.
{
    # A lone '-' is a positional operand, not an option.
    my $spec = _spec( '-', 'file.txt' );
    is_deeply( $spec->{patterns}, ['-'], 'parse: a lone - is the pattern' );
    is_deeply( $spec->{paths}, ['file.txt'], 'parse: the path follows a lone - pattern' );
    my $spec2 = _spec( 'needle', '-' );
    is_deeply( $spec2->{patterns}, ['needle'], 'parse: the pattern comes before a lone - path' );
    is_deeply( $spec2->{paths}, ['-'], 'parse: a lone - is a path' );
}
{
    # An argument that starts with '-' but is neither a long option nor a
    # short-option bundle dies naming it.
    my $ok = eval { _spec( '-5', 'foo', 'file.txt' ); 1 };
    ok( !$ok, 'parse: -5 dies' );
    like( $@, qr/unsupported grep option '-5'/, 'parse: -5 is named' );
}
{
    # No mocks, no match: real grep returns 1, and the dispatch gate stays
    # shut because this is not Windows (or because grep resolves there).
    my @none = grep_matching_files( args => [ 'zzz-no-match', $one ] );
    is_deeply( \@none, [], 'control: exit 1 without the Windows gate returns an empty list' );
}
{
    # Windows mocked true but grep resolving: exit 1, the gate's third term
    # is false, so the gate stays shut and the native fallback does not run.
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::OpenFileGrep::is_real_windows = sub { 1 };
    my @none = grep_matching_files( args => [ 'zzz-no-match', $one ] );
    is_deeply( \@none, [], 'control: exit 1 with grep resolving returns an empty list' );
}
{
    # No args at all: the args default to an empty list and usage dies.
    my $ok = eval { grep_matching_files(); 1 };
    ok( !$ok, 'grep_matching_files: no args dies' );
    like( $@, qr/Usage: d2 of grep/, 'grep_matching_files: no args dies with usage' );
}

# A second tree, so these additions cannot change the first tree's counts.
my $root2 = tempdir( CLEANUP => 1 );
my $multi = _write_file( $root2, 'multi.txt', "needle one\nplain\nneedle two\n" );
{
    # Two matches in one file: the file is returned once, not twice.
    my @found = _with_fake_grep(
        sub {
            _with_no_grep( sub { grep_matching_files( args => [ 'needle', $multi ] ) } );
        }
    );
    my $expected = $multi;
    $expected =~ s{/}{\\}g;
    is_deeply( \@found, [$expected], 'grep absent: a file matching twice is returned once' );
}
{
    # A file whose name holds a colon-digit pattern: the first ":digits:"
    # in the output is not the file boundary, so the parser tries the next one.
    SKIP: {
        skip 'colons are not allowed in Windows file names', 2 if $^O eq 'MSWin32';
        my $colon = _write_file( $root2, 'x:12:y.txt', "needle colon\n" );
        my @found = _with_fake_grep(
            sub {
                _with_no_grep( sub { grep_matching_files( args => [ 'needle', $colon ] ) } );
            }
        );
        my $expected = $colon;
        $expected =~ s{/}{\\}g;
        is_deeply( \@found, [$expected], 'grep absent: a colon-digit file name is found' );
        is( scalar @found, 1, 'grep absent: the colon-digit file is returned once' );
    }
}
{
    # _native_grep_dir on a directory that does not exist: stat fails, the
    # ancestor check is skipped, opendir fails and the error is recorded.
    my $gone = File::Spec->catdir( $root2, 'gone' );
    my $spec = _spec( '-r', 'needle', $gone );
    my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $gone, [] );
    is_deeply( \@lines, [], 'dir: a missing directory gives no lines' );
    is( scalar @{ $spec->{errors} }, 1, 'dir: a missing directory records one error' );
    like( $spec->{errors}[0], qr/\Q$gone\E/, 'dir: the error names the missing directory' );
}
{
    # A dangling symlink is neither a directory nor a file: it is skipped silently.
    SKIP: {
        my $dangling = File::Spec->catfile( $root2, 'dangling.txt' );
        my $target = File::Spec->catfile( $root2, 'never-there.txt' );
        skip 'symlinks need privileges on this box', 2 if !_try_symlink( $target, $dangling );
        my $spec = _spec( '-r', 'needle', $root2 );
        my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $root2, [] );
        ok( !( grep { /\Q$dangling\E/ } @lines ), 'dir: a dangling symlink contributes no lines' );
        is_deeply( $spec->{errors}, [], 'dir: a dangling symlink records no error' );
    }
}
{
    # A non-regular entry that is not a symlink is skipped silently.
    SKIP: {
        skip 'mkfifo is not available on Windows', 2 if $^O eq 'MSWin32';
        require POSIX;
        my $fifo = File::Spec->catfile( $root2, 'pipe' );
        skip 'mkfifo failed on this box', 2 if !eval { POSIX::mkfifo( $fifo, 0644 ); 1 };
        my $spec = _spec( '-r', 'needle', $root2 );
        my @lines = Developer::Dashboard::CLI::OpenFileGrep::_native_grep_dir( $spec, $root2, [] );
        ok( !( grep { /\Q$fifo\E/ } @lines ), 'dir: a FIFO contributes no lines' );
        is_deeply( $spec->{errors}, [], 'dir: a FIFO records no error' );
    }
}

done_testing();

__END__

=head1 NAME

t/1005-openfile-grep-native.t - tests for the OpenFileGrep native fallback (M1 coverage programme)

=head1 PURPOSE

Pin the Perl-native grep fallback in
C<Developer::Dashboard::CLI::OpenFileGrep>, which runs when no system
grep is installed: the eight subroutines C<native_grep_usage>,
C<_native_grep_output>, C<_parse_native_grep_args>,
C<_native_grep_set_directories>, C<_native_grep_path>, C<_native_grep_dir>,
C<_native_grep_file> and C<_native_grep_handle>, plus the
C<grep_matching_files> dispatch gate that calls the fallback when the
system grep exit code is 1 on real Windows and no grep resolves. The
tests call the private subroutines directly and drive
C<grep_matching_files> with grep absent (a fake grep on PATH that exits
1, C<is_real_windows> mocked true, C<command_in_path> mocked to find
nothing), so the fallback runs on every leg, including the Unix legs
where coverage is measured.

=head1 WHY IT EXISTS

The suite always finds system grep, so the fallback never runs and its
eight subroutines have no coverage: a change to the fallback could break
the plain-Windows search without any test noticing. The fallback is the
only search a Windows box without grep has, and its output must stay
identical in shape to system grep's (file:line:content) because the same
parser decodes both. These tests pin the fallback's behaviour directly,
so the coverage re-measure shows OpenFileGrep's numbers up and a
regression in the fallback fails here first.

=head1 WHEN TO USE

When the native fallback changes (a new grep option to honour, a change
to the directory walk, the symlink rules or the binary handling), when
C<grep_matching_files> changes how it settles the ambiguous exit 1, or
when C<d2 of grep> misbehaves on a box with no system grep. Also when
the coverage report shows OpenFileGrep's numbers down.

=head1 HOW TO USE

Run it directly with C<prove -lv t/1005-openfile-grep-native.t> while
iterating, then keep it green under C<prove -lr t> before release. The
tests build a temp tree with known content, call the eight subroutines
directly, and assert both sides of every two-outcome condition in the
fallback: -q prints vs suppresses, -a searches binary as text vs a NUL
byte stops the search, -v inverts vs not, -i matches case-insensitively
vs not, -w word vs substring, -x whole line vs partial, -d read vs skip
vs recurse, -r vs -R on symlinked directories, a cycle on the ancestor
stack vs not, a directory with vs without recursion, a missing path vs a
present one, and an unreadable directory vs a readable one. The
grep-absent tests use a fake grep and two mocks, localised to the
OpenFileGrep package, so they only apply inside those tests. Symlink
tests skip when symlink creation needs privileges; the unreadable
directory test skips on Windows and as root.

=head1 WHAT USES IT

It is used by the coverage programme (milestone M1) as the new coverage
for OpenFileGrep, by the full C<prove -lr t> suite, and by anyone
changing the native fallback or the C<d2 of grep> dispatch who needs to
know the fallback still behaves like system grep.

=head1 EXAMPLES

Example 1:

  prove -lv t/1005-openfile-grep-native.t

Run the native fallback checks by themselves while changing the fallback
or the dispatch gate.

Example 2:

  prove -lv t/05-cli-smoke.t

Run the smoke tests alongside it to see grep_matching_files through the
real system grep as well as through the fallback.

Example 3:

  prove -lr t

Run the whole suite after the focused check to keep the fallback
contract aligned with the rest of the CLI.

=cut
