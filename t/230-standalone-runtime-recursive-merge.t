#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Developer::Dashboard::Pax::StandaloneRuntime;

my $PKG = 'DD1040TestFixturePkg';

sub install {
    my (%sub) = @_;
    no strict 'refs';
    Developer::Dashboard::Pax::StandaloneRuntime::_install_compiled_sub($PKG, \%sub);
}

# --- config_merge_hashes: recurses on nested plain-HASH values ---
{
    install(name => 'merge_hashes_leaf', op => 'return_literal', value => 'unused');
    install(
        name                     => 'merge_named_array_leaf',
        op                       => 'config_merge_named_hash_array',
        merge_item_method        => 'merge_hashes_leaf',
    );
    install(
        name                    => 'config_merge_hashes',
        op                      => 'config_merge_hashes',
        merge_named_array_method => 'merge_named_array_leaf',
    );

    no strict 'refs';
    my $merge_cv = \&{"${PKG}::config_merge_hashes"};
    my $left  = { web => { host => '127.0.0.1', port => 1 } };
    my $right = { web => { port => 2, ssl => 1 } };
    my $merged = eval { $merge_cv->(undef, $left, $right) };
    my $err = $@;
    ok(!$err, "AC-1 config_merge_hashes recurses into a nested plain HASH without dying: $err")
        or diag($err);
    is_deeply(
        $merged,
        { web => { host => '127.0.0.1', port => 2, ssl => 1 } },
        'AC-1 the nested hash was actually deep-merged, not just non-crashing'
    ) if !$err;
}

# --- skill_dispatcher_merge_skill_hashes: same recursive shape ---
{
    install(
        name                      => 'merge_array_items_leaf',
        op                        => 'config_merge_named_hash_array',
        merge_item_method         => 'merge_hashes_leaf',
    );
    install(
        name                      => 'skill_dispatcher_merge_skill_hashes',
        op                        => 'skill_dispatcher_merge_skill_hashes',
        merge_array_items_method => 'merge_array_items_leaf',
    );

    no strict 'refs';
    my $merge_cv = \&{"${PKG}::skill_dispatcher_merge_skill_hashes"};
    my $left  = { commands => { start => { path => 'a' } } };
    my $right = { commands => { start => { path => 'b' }, stop => { path => 'c' } } };
    my $merged = eval { $merge_cv->(undef, $left, $right) };
    my $err = $@;
    ok(!$err, "AC-2 skill_dispatcher_merge_skill_hashes recurses into a nested plain HASH without dying: $err")
        or diag($err);
    is_deeply(
        $merged,
        { commands => { start => { path => 'b' }, stop => { path => 'c' } } },
        'AC-2 the nested command hash was actually deep-merged'
    ) if !$err;
}

# --- suggest_collect_skill_commands: recurses into nested skill dirs ---
{
    use File::Temp qw(tempdir);
    use File::Path qw(make_path);
    use File::Spec;

    install(name => 'logical_name_leaf', op => 'return_literal', value => undef);
    install(
        name                => 'suggest_collect_skill_commands',
        op                  => 'suggest_collect_skill_commands',
        logical_name_method => 'logical_name_leaf',
    );

    my $root = tempdir(CLEANUP => 1);
    my $nested = File::Spec->catdir($root, 'skills', 'inner');
    make_path($nested);

    no strict 'refs';
    my $collect_cv = \&{"${PKG}::suggest_collect_skill_commands"};
    my @entries;
    my $err = do {
        local $@;
        @entries = eval { $collect_cv->(undef, $root, 'prefix') };
        $@;
    };
    ok(!$err, "AC-3 suggest_collect_skill_commands recurses into a nested skill dir without dying: $err")
        or diag($err);
}

done_testing();

__END__

=head1 NAME

t/230-standalone-runtime-recursive-merge.t - pins DD-1040's fix for three
self-recursive compiled-sub ops that called _code_for() with a bare,
unqualified sub name instead of its package-qualified full name

=head1 PURPOSE

Reproduces and pins the fix for DD-1040: three compiled-sub op
implementations in StandaloneRuntime.pm ('config_merge_hashes',
'skill_dispatcher_merge_skill_hashes', 'suggest_collect_skill_commands')
recurse into themselves via C<_code_for($name)>, the bare unqualified sub
name, instead of C<_code_for($full)>, the package-qualified name captured
in the enclosing C<_install_compiled_sub> scope. C<_code_for()> does a raw
C<*{$full}{CODE}> typeglob lookup, so a bare name resolves relative to
whatever package C<_code_for()> itself compiles in
(Developer::Dashboard::Pax::StandaloneRuntime), not the package the sub
was actually installed into - returning undef, which crashes any caller
with "Can't use an undefined value as a subroutine reference" the first
time the recursive branch fires (e.g. 'dashboard init' deep-merging a
nested plain-hash config section).

=head1 WHY IT EXISTS

DD-1040 was filed after 'dashboard init' crashed on a compiled binary with
exactly that error at StandaloneRuntime.pm's config-merge helper. The bug
is invisible to a test that happens to install the op into
Developer::Dashboard::Pax::StandaloneRuntime itself, because the bare name
would then accidentally resolve to the right glob - so every fixture below
installs into a deliberately DIFFERENT scratch package
(DD1040TestFixturePkg) to force the real installed-elsewhere case that
'dashboard init' actually hits.

=head1 WHEN TO USE

Run as part of the full suite (C<prove -lr t>). Add a fourth case here if
another recursive compiled-sub op is ever found with the same bare-name
bug - grep StandaloneRuntime.pm for C<_code_for($name)> (bare) versus
C<_code_for($full)> (correct) to check for recurrences.

=head1 HOW TO USE

C<PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/230-standalone-runtime-recursive-merge.t>

No setup needed beyond the standard PERL5LIB preamble - the test installs
its own throwaway compiled subs via the real, unmodified
C<_install_compiled_sub> dispatcher and exercises them directly.

=head1 WHAT USES IT

Verifies lib/Developer/Dashboard/Pax/StandaloneRuntime.pm's
'config_merge_hashes', 'skill_dispatcher_merge_skill_hashes' and
'suggest_collect_skill_commands' op implementations. Nothing else calls
this file; it is exercised by prove/CI only.

=head1 EXAMPLES

  PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/230-standalone-runtime-recursive-merge.t

=cut
