use strict;
use warnings;
use Test::More;
use File::Spec;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "Cannot close $path: $!";
    return $source;
}

my $core = slurp( File::Spec->catfile('share', 'private-cli', '_dashboard-core') );
like( $core, qr/elsif\s*\(\s*\$cmd\s+eq\s+'web-foreground'/,
    'web foreground command remains available' );
like( $core, qr/my \$available = eval \{ require Developer::Dashboard::SystemMenu::Runner; 1 \}/,
    'external runner is loaded through an optional eval' );
like( $core,
    qr/if\s*\(\$available\)\s*\{\s*(?:\#[^\n]*\n\s*)*\$menu_runner = Developer::Dashboard::SystemMenu::Runner->new\(/,
    'installed runner constructor is deliberately outside the optional require eval; initialization failures remain fatal' );
like( $core, qr/next unless \$entry->\{indicator\}\{\$menu_platform\}/,
    'only active platform flags trigger runner discovery' );
like( $core, qr/\$menu_runner->run_with\(\$serve_web\)/,
    'installed runner wraps the foreground web service' );
like( $core, qr/else \{\s*\$serve_web->\(\);\s*\}/,
    'web server still starts without a menu runner' );
like( $core, qr{Can't locate Developer\\/Dashboard\\/SystemMenu\\/Runner\\\.pm\\b},
    'only the exact optional runner module path is treated as an ordinary no-op' );

# Compile the *actual* guard used in the launcher and verify both Perl error
# variants. A source-string check alone would miss a guard tightened to
# depend on a particular trailing "in @INC" message.
my ($source_guard) = $core =~ /^\s*elsif\s*\(\s*\$\@\s*!~\s*\/([^\n]+)\/\s*\)\s*\{/m;
ok( defined $source_guard, 'the optional-load exception guard can be inspected' );
if ( defined $source_guard ) {
    my $missing_runner = eval { qr/$source_guard/ };
    ok( $missing_runner && !$@, 'the optional-module guard is a valid regular expression' );
    if ($missing_runner) {
        like( "Can't locate Developer/Dashboard/SystemMenu/Runner.pm", $missing_runner,
            'absent optional module without an @INC suffix is ignored' );
        like( "Can't locate Developer/Dashboard/SystemMenu/Runner.pm in \@INC", $missing_runner,
            'normal Perl missing-module diagnostics are ignored' );
        unlike( "Can't locate Developer/Dashboard/SystemMenu/Other.pm in \@INC", $missing_runner,
            'missing dependency in installed menu integration is not ignored' );
        unlike( "Can't locate Developer/Dashboard/SystemMenu/Runner.pm_extra in \@INC", $missing_runner,
            'a different path sharing the runner prefix is not ignored' );
    }
}
like( $core, qr/\bdie \$@;/,
    'errors in installed integrations are not hidden' );

for my $file (
    File::Spec->catfile('lib', 'Developer', 'Dashboard', 'SystemMenu.pm'),
    File::Spec->catfile('lib', 'Developer', 'Dashboard', 'SystemMenu', 'Runner.pm'),
    File::Spec->catfile('lib', 'Developer', 'Dashboard', 'System', 'Menu.pm'),
    'SystemMenu.xs',
    'SystemMenuNative.h',
    File::Spec->catfile('native', 'system_menu_helper_linux.c'),
    File::Spec->catfile('native', 'system_menu_helper_mac.m'),
    File::Spec->catfile('native', 'system_menu_helper_win.c'),
) {
    ok( !-e $file, "$file is not shipped by core" );
}
done_testing;

__END__

=head1 NAME

t/241-system-menu-runner.t - optional integration boundary

=head1 PURPOSE

Ensure that native system-menu implementation is separately installed and
the core foreground web service retains its no-menu path.

=head1 WHY IT EXISTS

Native menu helpers and XS code belong to a separately released distribution.

=head1 WHEN TO USE

Run when changing the foreground service launcher or distribution contents.

=head1 HOW TO USE

  prove -lv t/241-system-menu-runner.t

=head1 EXAMPLES

A missing optional runner falls through to C<start_web>.

=head1 WHAT USES IT

The core Perl regression suite.

=cut
