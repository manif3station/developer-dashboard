use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Developer::Dashboard',
    VERSION_FROM => 'lib/Developer/Dashboard.pm',
    ABSTRACT     => 'Project-neutral local developer dashboard runtime',
    AUTHOR       => 'Developer Dashboard Contributors',
    EXE_FILES    => ['bin/dashboard'],
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
        'JSON::XS'              => 0,
        'Capture::Tiny'         => 0,
        'Digest::SHA'           => 0,
        'MIME::Base64'          => 0,
        'IO::Compress::Gzip'    => 0,
        'IO::Uncompress::Gunzip'=> 0,
        'HTTP::Daemon'          => 0,
        'HTTP::Status'          => 0,
        'Template'              => 0,
        'URI::Escape'           => 0,
        'Time::HiRes'           => 0,
        'POSIX'                 => 0,
    },
    LICENSE      => 'perl',
    META_MERGE   => {
        resources => {
            repository => 'https://example.invalid/developer-dashboard',
        },
    },
);
