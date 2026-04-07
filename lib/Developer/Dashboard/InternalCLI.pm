package Developer::Dashboard::InternalCLI;

use strict;
use warnings;

our $VERSION = '1.84';

use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Spec;
use File::ShareDir qw(dist_dir);

# helper_names()
# Returns the built-in private helper command names that dashboard manages.
# Input: none.
# Output: ordered list of helper command name strings.
sub helper_names {
    return qw(jq yq tomq propq iniq csvq xmlq of open-file ticket path paths ps1);
}

# helper_aliases()
# Returns the compatibility alias map for renamed helper commands.
# Input: none.
# Output: hash reference mapping older names to current helper names.
sub helper_aliases {
    return {
        pjq   => 'jq',
        pyq   => 'yq',
        ptomq => 'tomq',
        pjp   => 'propq',
    };
}

# canonical_helper_name($name)
# Normalizes one helper command name to the current built-in helper name.
# Input: helper command string.
# Output: canonical helper name string or empty string when unsupported.
sub canonical_helper_name {
    my ($name) = @_;
    return '' if !defined $name || $name eq '';
    my %allowed = map { $_ => 1 } helper_names();
    return $name if $allowed{$name};
    my $aliases = helper_aliases();
    return $aliases->{$name} || '';
}

# helper_path(%args)
# Resolves one private helper executable path under the home runtime CLI root.
# Input: path registry object plus helper command name.
# Output: helper file path string.
sub helper_path {
    my (%args) = @_;
    my $paths = $args{paths} || die 'Missing paths registry';
    my $name  = canonical_helper_name( $args{name} );
    die "Unsupported helper command '$args{name}'" if $name eq '';
    return File::Spec->catfile( _helper_install_root($paths), $name );
}

# helper_content($name)
# Loads one shipped private helper executable source body from the helper asset
# directory.
# Input: canonical helper command name.
# Output: full executable source text string.
sub helper_content {
    my ($name) = @_;
    $name = canonical_helper_name($name);
    die "Unsupported helper command '$name'" if $name eq '';
    my $path = _helper_asset_path($name);
    open my $fh, '<:raw', $path or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh or die "Unable to close $path: $!";
    return $content;
}

# ensure_helpers(%args)
# Seeds the built-in private helper executables into the home runtime CLI root.
# Input: path registry object.
# Output: array reference of written helper file paths.
sub ensure_helpers {
    my (%args) = @_;
    my $paths = $args{paths} || die 'Missing paths registry';

    my @written;
    for my $name ( helper_names() ) {
        my $target = helper_path( paths => $paths, name => $name );
        my $source = _helper_asset_path($name);
        $paths->ensure_dir( _helper_install_root($paths) );
        copy( $source, $target ) or die "Unable to copy $source to $target: $!";
        $paths->secure_file_permissions( $target, executable => 1 );
        push @written, $target;
    }

    return \@written;
}

# _helper_install_root($paths)
# Returns the home runtime CLI root used for built-in helper staging.
# Input: path registry object.
# Output: directory path string.
sub _helper_install_root {
    my ($paths) = @_;
    return File::Spec->catdir( $paths->home_runtime_root, 'cli' );
}

# _helper_asset_path($name)
# Resolves one private helper asset path from the repo share tree during
# development or from the installed distribution share dir after install.
# Input: canonical helper command name.
# Output: absolute helper asset file path string.
sub _helper_asset_path {
    my ($name) = @_;
    my $repo_path = File::Spec->catfile( _repo_private_cli_root(), $name );
    return $repo_path if -f $repo_path;
    return File::Spec->catfile( _shared_private_cli_root(), $name );
}

# _repo_private_cli_root()
# Resolves the repo-tree private CLI helper asset directory.
# Input: none.
# Output: absolute private helper asset directory path string.
sub _repo_private_cli_root {
    return File::Spec->catdir(
        dirname(__FILE__),
        File::Spec->updir,
        File::Spec->updir,
        File::Spec->updir,
        'share',
        'private-cli',
    );
}

# _shared_private_cli_root()
# Resolves the installed distribution share directory for private helper assets.
# Input: none.
# Output: absolute helper asset directory path inside the installed dist share.
sub _shared_private_cli_root {
    return File::Spec->catdir( dist_dir('Developer-Dashboard'), 'private-cli' );
}

1;

__END__

=head1 NAME

Developer::Dashboard::InternalCLI - private runtime helper executable management

=head1 SYNOPSIS

  use Developer::Dashboard::InternalCLI;

  my $paths = Developer::Dashboard::PathRegistry->new(home => $ENV{HOME});
  Developer::Dashboard::InternalCLI::ensure_helpers(paths => $paths);

=head1 DESCRIPTION

This module manages the built-in private helper executables that Developer
Dashboard stages under F<~/.developer-dashboard/cli/> instead of exposing as
global system commands.

=head1 FUNCTIONS

=head2 helper_names, helper_aliases, canonical_helper_name, helper_content, helper_path, ensure_helpers

Build and seed the built-in private helper command files.

=cut
