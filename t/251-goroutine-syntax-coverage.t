#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use lib 'lib';
use Developer::Dashboard::GoRoutine;

is( Developer::Dashboard::GoRoutine::_skip_ws("  \n x", 0), 4, 'whitespace skipper advances to code' );
is( Developer::Dashboard::GoRoutine::_skip_ws('x', 0), 0, 'whitespace skipper leaves code position unchanged' );
is( Developer::Dashboard::GoRoutine::_matching_delim('({[x]})', 0), 6, 'delimiter matcher handles nested delimiters' );
ok( !defined Developer::Dashboard::GoRoutine::_matching_delim('plain', 0), 'delimiter matcher rejects a non-opening character' );
ok( !defined Developer::Dashboard::GoRoutine::_matching_delim('(missing', 0), 'delimiter matcher reports unterminated input' );
is( Developer::Dashboard::GoRoutine::_statement_end('x = f(1; 2); tail', 0), 11,
    'statement finder ignores semicolons nested in delimiters' );
ok( !defined Developer::Dashboard::GoRoutine::_statement_end('x = 1', 0), 'statement finder reports a missing semicolon' );

is_deeply( [ Developer::Dashboard::GoRoutine::_variable_refs(' $one, @two, %three::four ') ],
    [ '$one', '@two', '%three::four' ], 'variable parser accepts supported scalar, array, and hash refs' );
for my $bad ( '1', '$one + 1', '$one $two' ) {
    my $ok = eval { Developer::Dashboard::GoRoutine::_variable_refs($bad); 1 };
    ok( !$ok, 'variable parser rejects malformed input' );
    like( $@, qr/share\(\) expects/, 'variable parser reports a specific contract error' );
}
is( Developer::Dashboard::GoRoutine::_refs_expr('$one', '@two'), '\\$one, \\@two',
    'reference expression builder quotes each accepted variable' );

my @group = Developer::Dashboard::GoRoutine::_rewrite_share_at('share my ($one, @two) = values;', 0);
is( $group[0], length('share my ($one, @two) = values;'), 'grouped share rewrite consumes the complete declaration' );
like( $group[1], qr/_share_many\(\\\$one, \\\@two\)/,
    'grouped share rewrite emits native share-many registration' );
ok( !defined scalar Developer::Dashboard::GoRoutine::_rewrite_share_at('share my $one;', 0),
    'scalar declaration remains on the lvalue share path' );
my @existing = Developer::Dashboard::GoRoutine::_rewrite_share_at('share $one, @two;', 0);
is( $existing[0], length('share $one, @two;'), 'existing-variable share rewrite consumes its statement' );
like( $existing[1], qr/_share_many\(\\\$one, \\\@two\)/,
    'existing-variable share rewrite registers each reference' );
my $bad_group = eval { Developer::Dashboard::GoRoutine::_rewrite_share_at('share my ($one + 1);', 0); 1 };
ok( !$bad_group, 'grouped share rejects expressions instead of variable declarations' );

my @named = Developer::Dashboard::GoRoutine::_rewrite_go_at('go do_work(1, nested(2));', 0);
like( $named[1], qr/_go_call\(\\&do_work, 1, nested\(2\)\)/,
    'named go-call syntax preserves nested argument expressions' );
ok( !defined scalar Developer::Dashboard::GoRoutine::_rewrite_go_at('go sub { 1 };', 0),
    'anonymous go block remains on the native go call path' );
my $bad_call = eval { Developer::Dashboard::GoRoutine::_rewrite_go_at('go do_work(1', 0); 1 };
ok( !$bad_call, 'named go-call rejects an unterminated argument list' );
like( $@, qr/unterminated go/, 'unterminated go-call has a clear error' );

my @open_share = Developer::Dashboard::GoRoutine::_rewrite_open_share_at("open share my \$fh, '<', \$path;", 0);
like( $open_share[1], qr/open \$fh, '<', \$path;.*_share_many/s,
    'open-share rewrite retains open arguments and registers the handle' );
ok( !defined scalar Developer::Dashboard::GoRoutine::_rewrite_open_share_at('open my $fh, q{<}, $path;', 0),
    'ordinary open does not enter the shared-handle rewrite' );
my $rewritten = Developer::Dashboard::GoRoutine::_rewrite_user_syntax('go do_work(1); share $one, @two;');
like( $rewritten, qr/_go_call/, 'user syntax rewrite transforms named go calls' );
like( $rewritten, qr/_share_many/, 'user syntax rewrite transforms aggregate shares' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::go = sub { $_[0] };
    my $called = 0;
    my $worker = Developer::Dashboard::GoRoutine::_go_call( sub { $called += $_[0] }, 3 );
    is( ref($worker), 'CODE', 'named-call helper delegates worker creation to go' );
    $worker->();
    is( $called, 3, 'named-call helper preserves evaluated arguments' );
}
my $bad_target = eval { Developer::Dashboard::GoRoutine::_go_call('not-code'); 1 };
ok( !$bad_target, 'named-call helper rejects non-code target' );
like( $@, qr/target is not a CODE reference/, 'named-call target failure is explicit' );

done_testing;

__END__

=head1 NAME

t/251-goroutine-syntax-coverage.t - verify GoRoutine syntax rewriting without workers

=head1 PURPOSE

Exercises the GoRoutine lexer helpers, sharing declaration transformer, named
worker-call transformer, and argument validation without starting any worker.

=head1 WHY IT EXISTS

The parser is part of the public source syntax and has many failure branches.
Keeping those branches in a deterministic, thread-free test allows the ordinary
coverage gate to measure them without instrumenting Perl ithreads.

=head1 WHEN TO USE

Run this test when changing GoRoutine syntax, declaration rewriting, or named
worker calls:

    d2 docker compose exec dev prove -lv t/251-goroutine-syntax-coverage.t

=head1 HOW TO USE

The test loads the production GoRoutine module, calls its parser helpers with
valid and malformed source fragments, and replaces only the worker launcher
for the named-call delegation check.

=head1 WHAT USES IT

The repository test suite and four-metric coverage gate use this file to cover
the Perl source transformer independently from native-thread integration tests.

=head1 EXAMPLES

The test verifies nested delimiter matching, declarations such as
C<share my ($a, @b) = ...>, and named calls such as C<go work(1, 2)> while
checking malformed arguments fail with explicit diagnostics.

=cut
