use strict;
use warnings;

use ExtUtils::MakeMaker;
use File::ShareDir::Install qw(install_share);
use Config;
use File::Spec;
use Cwd qw(cwd);

install_share dist => 'share';

# Find a local::lib root with installed modules, preferring the project-local
# tree and then the current user's Perl tree. HOME is common on Unix and
# USERPROFILE is the Windows fallback. This keeps generated test commands able
# to discover developer dependencies without interpolating an unset variable.
my $local_lib_root;
my @local_lib_candidates = ('.perl5');
my $home = $ENV{HOME};
$home = $ENV{USERPROFILE} if !defined $home || $home eq '';
push @local_lib_candidates, File::Spec->catdir( $home, 'perl5' )
  if defined $home && $home ne '';

for my $candidate (@local_lib_candidates) {
    my $lib = File::Spec->catdir( $candidate, 'lib', 'perl5' );
    my @module_dirs = (
        $lib,
        File::Spec->catdir( $lib, $Config{archname} ),
        File::Spec->catdir( $lib, $Config{version} ),
    );
    if ( grep { -d $_ && grep { -f $_ } glob( File::Spec->catfile( $_, '*.pm' ) ) } @module_dirs ) {
        $local_lib_root = $candidate;
        last;
    }
}
$local_lib_root ||= '.perl5';

WriteMakefile(
    NAME         => 'Developer::Dashboard',
    MIN_PERL_VERSION => '5.038',
    VERSION_FROM => 'lib/Developer/Dashboard/Version.pm',
    XS           => { 'HtmlEscape.xs' => 'HtmlEscape.c' },
    OBJECT       => 'HtmlEscape$(OBJ_EXT)',
    LIBS         => [ $^O eq 'linux' ? '-ldl' : q{} ],
    ABSTRACT     => 'Project-neutral local developer dashboard runtime',
    AUTHOR       => 'Developer Dashboard Contributors',
    EXE_FILES    => [
        'bin/dashboard',
        'bin/d2',
    ],
    PREREQ_PM    => {
        'strict'                => 0,
        'warnings'              => 0,
        'Cwd'                   => 0,
        'File::Basename'        => 0,
        'File::Path'            => 0,
        'File::Spec'            => 0,
        'File::Temp'            => 0,
        'File::Find'            => 0,
        'Cpanel::JSON::XS'      => '4.41',
        'Getopt::Long'          => 0,
        'HTML::Parser'          => '3.84',
        'HTTP::Date'            => '6.08',
        'HTTP::Tiny'            => '0.096',
        'HTTP::Request'         => 0,
        'JSON::XS'              => '4.04',
        'LWP::Protocol::https'  => '6.07',
        'LWP::UserAgent'        => '6.83',
        'YAML'                  => '1.30',
        'YAML::XS'              => '0.903.0',
        'TOML::Parser'          => 0,
        'Capture::Tiny'         => '0.24',
        'Digest::MD5'           => '2.25',
        'Crypt::URandom'        => '0.55',
        'Digest::SHA'           => '5.96',
        'String::Compare::ConstantTime' => '0.321',
        'Archive::Tar'          => '3.10',
        'Archive::Zip'          => '1.61',
        'MIME::Base64'          => 0,
        'Compress::Raw::Zlib'   => '2.220',
        'IO::Compress::Gzip'    => '2.220',
        'IO::Uncompress::Gunzip'=> '2.220',
        'Dancer2'               => '2.2.0',
        'Plack'                 => '1.0054',
        'Pod::Text'             => '6.1.1',
        'Socket'                => '2.041',
        'Starman'               => '0.4018',
        'Storable'              => '3.41',
        'Template'              => '3.103',
        'URI'                   => '5.36',
        'URI::Escape'           => '5.36',
        'XML::Parser'           => '2.48',
        'Time::HiRes'           => 0,
        'POSIX'                 => 0,
    },
    LICENSE      => 'mit',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker'    => 0,
        'File::ShareDir::Install' => 0,
    },
    META_MERGE   => {
        resources => {
            homepage   => 'https://github.mf/manif3station/developer-dashboard',
            bugtracker => {
                web => 'https://github.mf/manif3station/developer-dashboard/issues',
            },
            repository => {
                type => 'git',
                url  => 'git@github.mf:manif3station/developer-dashboard.git',
                web  => 'https://github.mf/manif3station/developer-dashboard',
            },
        },
        prereqs => {
            runtime => {
                recommends => {},
            },
        },
    },
);

package MY;

# _local_lib_perl5_paths()
# Resolves the selected local::lib root to the base, architecture, and active
# Perl-version directories used by the build's generated Perl launcher.
# Input: none; reads the detected root and active Perl Config values.
# Output: an ordered list of absolute module search paths.
sub _local_lib_perl5_paths {
    my $base = File::Spec->catdir( $local_lib_root, 'lib', 'perl5' );
    $base = File::Spec->rel2abs( $base, Cwd::cwd() );
    my @paths = ($base);
    for my $platform_dir ( @Config::Config{qw(archname version)} ) {
        my $path = File::Spec->catdir( $base, $platform_dir );
        push @paths, $path if -d $path;
    }
    return @paths;
}

# _write_local_lib_runner($paths)
# Writes a small Perl launcher that adds local::lib paths to PERL5LIB before
# executing the configured Perl with the original arguments. This lets child
# processes inherit the paths without make-specific export directives.
# Input: list of absolute local::lib directories.
# Output: relative generated launcher path; dies if writing or closing fails.
sub _write_local_lib_runner {
    my (@paths) = @_;
    my $runner = '.dd-perl5lib-runner.pl';
    my @quoted_paths = map {
        my $path = $_;
        $path =~ s/\\/\\\\/g;
        $path =~ s/'/\\'/g;
        "    '$path'";
    } @paths;
    open my $fh, '>', $runner or die "Unable to create $runner: $!";
    print {$fh} "use strict;\nuse warnings;\nuse Config;\n\n",
      "my \@local_lib_paths = (\n", join( ",\n", @quoted_paths ), ");\n",
      "my \$separator = quotemeta(\$Config{path_sep});\n",
      "my \@inherited = grep { length \$_ } split /\$separator/, \$ENV{PERL5LIB} // '';\n",
      "\$ENV{PERL5LIB} = join \$Config{path_sep}, \@local_lib_paths, \@inherited;\n",
      "my \$perl = \$^X;\nexec { \$perl } \$perl, \@ARGV;\n",
      "die \"Unable to execute \$perl: \$!\\n\";\n",
      "__END__\n\n=head1 NAME\n\n.dd-perl5lib-runner.pl - portable local Perl library launcher\n\n",
      "=head1 DESCRIPTION\n\nAdds the build's local::lib module directories to PERL5LIB, then replaces itself with the active Perl interpreter and forwards all arguments. It is generated beside the Makefile and removed by the clean target.\n\n",
      "=head1 EXAMPLE\n\n  perl .dd-perl5lib-runner.pl -MModule::Name -e 'print qq(ok\\n)'\n\n=cut\n",
      or die "Unable to write $runner: $!";
    close $fh or die "Unable to close $runner: $!";
    return $runner;
}

# postamble()
# Appends the File::ShareDir::Install postamble so packaged installs refresh
# dist share assets, then adds the home-runtime helper bootstrap hook used by
# checkout and local installs. A Perl launcher provides local module paths to
# MakeMaker commands and their children without make-specific export syntax.
# Input: ExtUtils::MakeMaker MY package object.
# Output: full make postamble text string.
sub postamble {
    my $self = shift;
    my $share_postamble = File::ShareDir::Install::postamble($self);
    my $runner = _write_local_lib_runner( _local_lib_perl5_paths() );

    return "FULLPERL = \$(PERL) $runner\n\n" . $share_postamble . <<'END_POSTAMBLE';
.PHONY: clean-local-perl5lib-runner
clean :: clean-local-perl5lib-runner

clean-local-perl5lib-runner:
	$(RM_F) .dd-perl5lib-runner.pl

.PHONY: install pure_install install-private-cli-tools
install ::
	$(NOECHO) $(PERL) -e "1;"

pure_install :: install-private-cli-tools

install-private-cli-tools :
	$(NOECHO) $(PERL) -e 'use File::Copy; use File::Path qw(make_path); use File::Spec; my $$home = $$ENV{HOME} || $$ENV{USERPROFILE} || eval { (getpwuid($$>))[7] } || die "Unable to resolve a home directory for the private CLI helper staging\n"; my $$cli_dir = File::Spec->catdir($$home, ".developer-dashboard", "cli"); make_path($$cli_dir) unless -d $$cli_dir; for my $$cmd (qw(_dashboard-core jq yq tomq propq iniq csvq xmlq of open-file workspace file files path paths ps1 encode decode indicator collector config auth api ask init cpan page action docker serve stop restart log shell doctor housekeeper skills which upgrade complete)) { my $$src = File::Spec->catfile("share", "private-cli", $$cmd); my $$dst = File::Spec->catfile($$cli_dir, $$cmd); if (-f $$src) { File::Copy::copy($$src, $$dst) or warn "Failed to copy $$src to $$dst: $$!"; chmod(0755, $$dst); print "Installed $$cmd to $$cli_dir\n"; } }'
END_POSTAMBLE
}

__END__

=head1 NAME

Makefile.PL - configure and generate the Developer::Dashboard build Makefile

=head1 DESCRIPTION

This script configures the Developer::Dashboard Perl distribution with
ExtUtils::MakeMaker. It declares runtime and configuration prerequisites,
version metadata, executable scripts, XS extension sources, shared assets, and
repository metadata. Its MakeMaker postamble installs private command helpers
and removes its generated local-library launcher during C<make clean>.

When local::lib modules are present under C<.perl5> or the current user's
C<perl5> directory, the generated Makefile runs Perl commands through a small
generated launcher. The user's directory is resolved from C<HOME> on Unix or
C<USERPROFILE> on Windows; if neither variable exists, only C<.perl5> is
considered. The launcher adds the active local-library directories to
C<PERL5LIB> before running Perl and forwarding the original arguments. Child
commands inherit the same environment. The launcher avoids GNU make-only
assignment and export syntax, so source distributions remain parseable by BSD
and Solaris make.

=head1 WHEN TO USE

Run this configuration script when building or testing a source checkout with
MakeMaker. Dist::Zilla invokes it as part of distribution testing and
installation.

=head1 HOW TO USE

  perl Makefile.PL
  make
  make test
  make clean

The generated Makefile and launcher belong to the build tree; neither is
required as a checked-in source file.

=head1 EXAMPLES

Example 1: configure and test a source checkout:

  perl Makefile.PL && make test

Example 2: remove generated build files after testing:

  make clean

=head1 USERS

Maintainers and source-distribution installers use this file to configure the
distribution. CPAN testers use the generated Makefile with the platform's
native make implementation.

=cut
