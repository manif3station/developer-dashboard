#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 18;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(cwd);

# Test the static files serving functionality
BEGIN {
    use_ok('Developer::Dashboard::Web::App');
}

# Create mock app for testing
sub create_mock_app {
    my %args = @_;
    return bless \%args, 'Developer::Dashboard::Web::App';
}

# Test: _get_content_type for JavaScript
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('js', 'script.js');
    is($ct, 'application/javascript; charset=utf-8', 'JS content type correct');
}

# Test: _get_content_type for CSS
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('css', 'style.css');
    is($ct, 'text/css; charset=utf-8', 'CSS content type correct');
}

# Test: _get_content_type for JSON
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'data.json');
    is($ct, 'application/json; charset=utf-8', 'JSON content type correct');
}

# Test: _get_content_type for XML
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'config.xml');
    is($ct, 'application/xml; charset=utf-8', 'XML content type correct');
}

# Test: _get_content_type for PNG
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'image.png');
    is($ct, 'image/png', 'PNG content type correct');
}

# Test: _get_content_type for JPEG
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'photo.jpg');
    is($ct, 'image/jpeg', 'JPEG content type correct');
}

# Test: _get_content_type for GIF
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'animation.gif');
    is($ct, 'image/gif', 'GIF content type correct');
}

# Test: _get_content_type for WebP
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'image.webp');
    is($ct, 'image/webp', 'WebP content type correct');
}

# Test: _get_content_type for SVG
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'icon.svg');
    is($ct, 'image/svg+xml', 'SVG content type correct');
}

# Test: _get_content_type for ICO
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'favicon.ico');
    is($ct, 'image/x-icon', 'ICO content type correct');
}

# Test: _get_content_type for HTML
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'index.html');
    is($ct, 'text/html; charset=utf-8', 'HTML content type correct');
}

# Test: _get_content_type for unknown
{
    my $app = create_mock_app();
    my $ct = $app->_get_content_type('others', 'unknown.xyz');
    is($ct, 'application/octet-stream', 'Unknown content type is octet-stream');
}

# Test: _serve_static_file with directory traversal (security)
{
    my $app = create_mock_app();
    my $response = $app->_serve_static_file('js', '../../../etc/passwd');
    is($response->[0], 400, 'Directory traversal blocked');
}

# Test: _serve_static_file with nonexistent file
{
    my $app = create_mock_app();
    my $response = $app->_serve_static_file('js', 'nonexistent.js');
    is($response->[0], 404, 'Nonexistent file returns 404');
}

# Test: _serve_static_file with actual file (if it exists)
SKIP: {
    my $public_dir = File::Spec->catdir(
        $ENV{HOME} || $ENV{USERPROFILE} || '/root',
        '.developer-dashboard',
        'dashboard',
        'public',
        'js'
    );
    
    skip "Public directory not found", 3 unless -d $public_dir;
    
    # Create a test file
    my $test_file = File::Spec->catfile($public_dir, 'test.js');
    open my $fh, '>', $test_file or die "Cannot create test file: $!";
    print $fh 'console.log("test");';
    close $fh;
    
    my $app = create_mock_app();
    my $response = $app->_serve_static_file('js', 'test.js');
    
    is($response->[0], 200, 'Valid file returns 200');
    is($response->[1], 'application/javascript; charset=utf-8', 'Correct content type');
    is($response->[2], 'console.log("test");', 'File content correct');
    
    # Clean up
    unlink $test_file;
}

done_testing();

__END__

=head1 NAME

web_app_static_files.t - Unit tests for static file serving functionality

=head1 DESCRIPTION

Tests the static file serving functionality added to Developer::Dashboard::Web::App.
Verifies MIME type detection, security checks, and file serving.

=head1 TESTS

- Content type detection for various file types (JS, CSS, JSON, images, etc)
- Directory traversal attack prevention
- 404 handling for missing files
- File content serving

=cut
