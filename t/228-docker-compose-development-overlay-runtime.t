#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

use lib "$FindBin::Bin/../lib";

use Developer::Dashboard::Pax::CodeUnitCompiler;
use Developer::Dashboard::Pax::StandaloneRuntime;

my $source_path = File::Spec->catfile(
    $FindBin::Bin, '..', 'lib', 'Developer', 'Dashboard', 'DockerCompose.pm'
);
open my $source_fh, '<:raw', $source_path or die "Unable to read $source_path: $!";
my $source = do { local $/; <$source_fh> };
close $source_fh or die "Unable to close $source_path: $!";

my %operations = (
    _service_development_marker_path => 'docker_compose_service_development_marker_path',
    _service_folder_is_development  => 'docker_compose_service_folder_is_development',
    _discover_service_files          => 'docker_compose_discover_service_files',
    enable_service_development       => 'docker_compose_enable_service_development',
    disable_service_development      => 'docker_compose_disable_service_development',
);
my %compiled;
for my $name ( sort keys %operations ) {
    my $descriptor = Developer::Dashboard::Pax::CodeUnitCompiler::_compile_declared_sub_from_source(
        $source,
        "Developer::Dashboard::DockerCompose::$name",
    );
    is( $descriptor->{op}, $operations{$name}, "PAX compiler recognizes $name" );
    $compiled{$name} = $descriptor;
}

my $root = tempdir( CLEANUP => 1 );
my $service_root = File::Spec->catdir( $root, 'green' );
make_path($service_root);
my $base_path = File::Spec->catfile( $service_root, 'compose.yml' );
my $development_path = File::Spec->catfile( $service_root, 'development.compose.yml' );
for my $entry (
    [ $base_path, "services:\n  green:\n    image: alpine\n" ],
    [ $development_path, "services:\n  green:\n    environment:\n      MODE: development\n" ],
) {
    open my $fh, '>', $entry->[0] or die "Unable to write $entry->[0]: $!";
    print {$fh} $entry->[1];
    close $fh or die "Unable to close $entry->[0]: $!";
}

my $package = 'Problem15::CompiledDockerCompose';
{
    no strict 'refs';
    *{"${package}::_service_toggle_root"} = sub { return $root };
    *{"${package}::_service_lookup_roots"} = sub { return ($root) };
    *{"${package}::_service_folder_is_disabled"} = sub { return 0 };
}

$compiled{_service_development_marker_path}{toggle_root_method} = "${package}::_service_toggle_root";
$compiled{_service_folder_is_development}{lookup_roots_method} = "${package}::_service_lookup_roots";
$compiled{_discover_service_files}{service_disabled_method} = "${package}::_service_folder_is_disabled";
$compiled{_discover_service_files}{service_development_method} = "${package}::_service_folder_is_development";
$compiled{_discover_service_files}{lookup_roots_method} = "${package}::_service_lookup_roots";
$compiled{enable_service_development}{development_marker_method} = "${package}::_service_development_marker_path";
$compiled{disable_service_development}{development_marker_method} = "${package}::_service_development_marker_path";
for my $name ( sort keys %operations ) {
    Developer::Dashboard::Pax::StandaloneRuntime::_install_compiled_sub( $package, $compiled{$name} );
}

my $self = {};
my @base_only = do {
    no strict 'refs';
    &{"${package}::_discover_service_files"}( $self, service => 'green', project_root => $root );
};
is_deeply( \@base_only, [$base_path], 'compiled runtime loads base and ignores an unmarked development file' );

my $enabled = do {
    no strict 'refs';
    &{"${package}::enable_service_development"}( $self, service => 'green' );
};
ok( -f $enabled->{marker}, 'compiled runtime creates the develop.yml marker' );
my @with_overlay = do {
    no strict 'refs';
    &{"${package}::_discover_service_files"}( $self, service => 'green', project_root => $root );
};
is_deeply( \@with_overlay, [ $base_path, $development_path ], 'compiled runtime loads the development overlay after the base' );

my $disabled = do {
    no strict 'refs';
    &{"${package}::disable_service_development"}( $self, service => 'green' );
};
ok( !-e $disabled->{marker}, 'compiled runtime removes the develop.yml marker' );

my $missing_overlay = do {
    no strict 'refs';
    &{"${package}::enable_service_development"}( $self, service => 'green' );
};
unlink $development_path or die "Unable to remove $development_path: $!";
my @base_without_overlay = do {
    no strict 'refs';
    &{"${package}::_discover_service_files"}( $self, service => 'green', project_root => $root );
};
is_deeply( \@base_without_overlay, [$base_path], 'compiled runtime skips a missing opted-in overlay without error' );

my $escape_error = eval {
    no strict 'refs';
    &{"${package}::enable_service_development"}( $self, service => '../outside' );
    1;
} ? '' : $@;
like( $escape_error, qr/escapes the docker config root/, 'compiled marker command refuses a service path outside its root' );

done_testing;

__END__

=head1 NAME

228-docker-compose-development-overlay-runtime.t - PAX runtime parity tests for Docker development overlays

=head1 PURPOSE

This test verifies that the PAX compiler recognizes the development-marker and overlay-discovery methods in C<DockerCompose.pm>, and that their standalone runtime implementations preserve the same file-selection behavior as the source module.

=head1 WHY IT EXISTS

The PAX standalone runtime substitutes selected Perl methods with generated operations. A source-only unit test would miss a stale compiler mapping or a runtime operation that still applied the old development-over-base fallback. This test pins the compiled behavior directly.

=head1 WHEN TO USE

Use this test when changing Docker service discovery, development marker commands, the DockerCompose PAX operation descriptors, or their standalone runtime closures.

=head1 HOW TO USE

Run C<prove -lv t/228-docker-compose-development-overlay-runtime.t> from the repository root. The test creates an isolated temporary service folder, invokes the real standalone runtime dispatcher, and removes its fixture directory automatically.

=head1 WHAT USES IT

The repository test suite and the PAX compiler/runtime regression checks use this file to keep compiled Docker service behavior aligned with the Perl module.

=head1 EXAMPLES

=over 4

=item 1

  prove -lv t/228-docker-compose-development-overlay-runtime.t

Verify the PAX development-marker operation mappings and overlay ordering.

=item 2

  prove -lr t

Run the focused parity guard with the full repository suite.

=back

=cut
