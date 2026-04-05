use strict;
use warnings;

use ExtUtils::MakeMaker;
use File::Spec;

WriteMakefile(
    NAME         => 'Developer::Dashboard',
    VERSION_FROM => 'lib/Developer::Dashboard.pm',
    ABSTRACT     => 'Project-neutral local developer dashboard runtime',
    AUTHOR       => 'Developer Dashboard Contributors',
    EXE_FILES    => [
        'bin/dashboard',
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
        'Getopt::Long'          => 0,
        'HTTP::Request'         => 0,
        'JSON::XS'              => 0,
        'LWP::Protocol::https'  => 0,
        'LWP::UserAgent'        => 0,
        'YAML::XS'              => 0,
        'TOML::Tiny'            => 0,
        'Capture::Tiny'         => 0,
        'Digest::SHA'           => 0,
        'MIME::Base64'          => 0,
        'IO::Compress::Gzip'    => 0,
        'IO::Uncompress::Gunzip'=> 0,
        'HTTP::Daemon'          => 0,
        'HTTP::Status'          => 0,
        'Template'              => 0,
        'URI'                   => 0,
        'URI::Escape'           => 0,
        'Time::HiRes'           => 0,
        'POSIX'                 => 0,
    },
    LICENSE      => 'perl',
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
    },
);

# Post-install hook: extract private CLI tools to ~/.developer-dashboard/cli/
sub MY::postamble {
    return <<'END_POSTAMBLE';
install :: install-private-cli-tools

install-private-cli-tools :
	$(NOECHO) $(PERL) -e 'use File::Path qw(make_path); use File::Copy; my $$home = $$ENV{HOME} || (getpwuid($$>))[7]; my $$cli_dir = File::Spec->catdir($$home, ".developer-dashboard", "cli"); make_path($$cli_dir) unless -d $$cli_dir; for my $$cmd (qw(jq yq tomq propq iniq csvq xmlq)) { my $$src = File::Spec->catfile("private-cli", $$cmd); my $$dst = File::Spec->catfile($$cli_dir, $$cmd); if (-f $$src) { File::Copy::copy($$src, $$dst) or warn "Failed to copy $$src to $$dst: $$!"; chmod(0755, $$dst); print "Installed $$cmd to $$cli_dir\n"; } }'
END_POSTAMBLE
}
