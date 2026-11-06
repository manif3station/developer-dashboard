use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::XS ();

use lib 'lib';
use Developer::Dashboard::Config;
use Developer::Dashboard::PathRegistry;

my $paths = Developer::Dashboard::PathRegistry->new;
my $config = Developer::Dashboard::Config->for_paths($paths);
my $merged = $config->_merge_hashes(
    { indicators => [ { name => 'build', indicator => {
        macos => 1, windows => 0, ubuntu => 0,
    } } ] },
    { indicators => [
        { name => 'build', indicator => { windows => 1, ubuntu => 1 } },
        { name => 'tests', indicator => { macos => 0, ubuntu => 1 } },
    ] },
);
is_deeply(
    $merged->{indicators},
    [
        { name => 'build', indicator => { macos => 1, windows => 1, ubuntu => 1 } },
        { name => 'tests', indicator => { macos => 0, ubuntu => 1 } },
    ],
    'all three platform preferences merge by indicator name',
);

my $home = tempdir( CLEANUP => 1 );
my $layered_paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $layered_config = Developer::Dashboard::Config->for_paths($layered_paths);
my $global_file = $layered_config->_global_config_file;
make_path( dirname($global_file) );
open my $fh, '>:raw', $global_file or die "Unable to write $global_file: $!";
print {$fh} JSON::XS->new->canonical->encode( { version => 1 } )
  or die "Unable to write $global_file: $!";
close $fh or die "Unable to close $global_file: $!";
is_deeply(
    $layered_config->load_global( skill_config_entries => [] ),
    { version => 1 },
    'config without native menu preferences remains valid',
);

my $flags = JSON::XS->new->decode(
    '{"indicators":[{"name":"build","indicator":{"macos":1,"windows":1,"ubuntu":1}}]}'
);
open $fh, '>:raw', $global_file or die "Unable to write $global_file: $!";
print {$fh} JSON::XS->new->canonical->encode($flags)
  or die "Unable to write $global_file: $!";
close $fh or die "Unable to close $global_file: $!";
is_deeply(
    $layered_config->load_global( skill_config_entries => [] )->{indicators},
    $flags->{indicators},
    'menu preferences survive config loading without optional module',
);
my $extended = $config->_merge_hashes(
    $flags,
    { indicators => [ { name => 'build', indicator => { windows => 0 } } ] },
);
is_deeply(
    $extended->{indicators},
    [ { name => 'build', indicator => { macos => 1, windows => 0, ubuntu => 1 } } ],
    'one platform override leaves other preferences unchanged',
);
done_testing;

__END__

=head1 NAME

t/239-system-menu-config.t - preserve optional platform menu preferences

=head1 PURPOSE

Core config retains platform selectors without requiring native system-menu
modules.

=head1 WHY IT EXISTS

Menu integration has its own release cycle and optional installation.

=head1 WHEN TO USE

Run when changing configuration layering or optional menu integration.

=head1 HOW TO USE

  prove -lv t/239-system-menu-config.t

=head1 EXAMPLES

A named indicator can enable all three selectors with scalar C<1> values.

=head1 WHAT USES IT

The core Perl suite verifies the configuration compatibility contract.

=cut
