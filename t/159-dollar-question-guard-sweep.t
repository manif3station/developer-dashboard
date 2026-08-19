#!/usr/bin/env perl

use strict;
use warnings;

use File::Find qw(find);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

# _repo_path(@parts)
# Builds an absolute path rooted at the repository checkout, independent of
# the caller's own working directory.
# Input: path segment strings.
# Output: absolute path string.
sub _repo_path {
    return File::Spec->rel2abs( File::Spec->catfile( $RealBin, File::Spec->updir, @_ ) );
}

# DD-611: this baseline is DD-597's own still-open findings (verified against
# the live sweep at the time this gate was written: 25 hits, matching that
# card's own recorded count). DD-597 remains open and owned separately -
# fixing any of these subs is that ticket's work, not this gate's. Whoever
# fixes one removes it from this list as proof of the fix; anything left in
# the list that the sweep no longer finds is a stale entry, and this test
# fails on that mismatch exactly as loudly as it fails on a genuinely new,
# unguarded sub.
my %BASELINE = map { $_ => 1 } (
    'Developer/Dashboard/ActionRunner.pm::_background_child_exit_status',
    'Developer/Dashboard/ActionRunner.pm::_run_command',
    'Developer/Dashboard/CLI/Ticket.pm::tmux_command',
    'Developer/Dashboard/CLI/Upgrade.pm::_run_command',
    'Developer/Dashboard/CollectorRunner.pm::_replace_path_via_powershell',
    'Developer/Dashboard/CollectorRunner.pm::_spawn_windows_background_command',
    'Developer/Dashboard/CollectorRunner.pm::_run_command',
    'Developer/Dashboard/CollectorRunner.pm::_await_windows_command',
    'Developer/Dashboard/DockerCompose.pm::run',
    'Developer/Dashboard/PageRuntime.pm::_run_single_block',
    'Developer/Dashboard/Platform.pm::_exec_java_source',
    'Developer/Dashboard/RuntimeManager.pm::_replace_path_via_powershell',
    'Developer/Dashboard/RuntimeManager.pm::_send_signal',
    'Developer/Dashboard/RuntimeManager.pm::_spawn_windows_background_command',
    'Developer/Dashboard/RuntimeManager.pm::_pkill_perl',
    'Developer/Dashboard/RuntimeManager.pm::_ps_processes',
    'Developer/Dashboard/RuntimeManager.pm::_listener_pids_for_port',
    'Developer/Dashboard/RuntimeManager.pm::_listener_pids_for_port_via_lsof',
    'Developer/Dashboard/RuntimeManager.pm::_listener_pids_for_port_via_netstat',
    'Developer/Dashboard/SkillDispatcher.pm::_run_child_command_streaming',
    'Developer/Dashboard/SkillManager.pm::_run_streaming_command',
    'Developer/Dashboard/UpdateManager.pm::run',
    'Developer/Dashboard/Web/App.pm::_ip_pairs_from_ip',
    'Developer/Dashboard/Web/App.pm::_ip_pairs_from_ipconfig',
    'Developer/Dashboard/Web/App.pm::_ip_pairs_from_ifconfig',
);

# _subs_in_file($path)
# Extracts every top-level named sub's source text from one Perl module,
# using this codebase's own consistent formatting convention (an opening
# "sub name {" line, and either a same-line close for a one-liner or a lone
# "}" line at column 0 for a multi-line body) rather than a full parser -
# deliberately dependency-free so this gate needs nothing beyond core Perl.
# Input: file path string.
# Output: list of { name => ..., body => ... } hash references.
sub _subs_in_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my @lines = <$fh>;
    close $fh or die "Unable to close $path: $!";

    my @subs;
    my $i = 0;
    while ( $i <= $#lines ) {
        if ( $lines[$i] =~ /\A sub \s+ (\w+) /x ) {
            my $name  = $1;
            my $body  = $lines[$i];
            if ( $body !~ /\{ .* \}/x ) {
                $i++;
                while ( $i <= $#lines && $lines[$i] !~ /\A \} \s* \z/x ) {
                    $body .= $lines[$i];
                    $i++;
                }
                $body .= $lines[$i] if $i <= $#lines;
            }
            push @subs, { name => $name, body => $body };
        }
        $i++;
    }
    return @subs;
}

# _unguarded_dollar_question_hits($lib_dir)
# Sweeps every .pm file under a lib/ root for a sub that reads the global $?
# without a preceding "local $?;" guard anywhere in its own body - the shape
# DD-585/589-593/597 exist to fix, where a query helper's own subprocess call
# leaves $? mutated for whatever the CALLER reads next.
# Input: lib/ directory path string.
# Output: hash reference keyed "relative/File.pm::sub_name" for every hit.
sub _unguarded_dollar_question_hits {
    my ($lib_dir) = @_;
    my @files;
    find( { wanted => sub { push @files, $File::Find::name if /\.pm\z/ }, no_chdir => 1 }, $lib_dir );

    my %hits;
    for my $file ( sort @files ) {
        my ($rel) = $file =~ /\Q$lib_dir\E\/?(.*)/;
        for my $sub ( _subs_in_file($file) ) {
            next if $sub->{body} !~ /\$\?/;
            next if $sub->{body} =~ /local\s+\$\?/;
            $hits{"$rel\::$sub->{name}"} = 1;
        }
    }
    return \%hits;
}

my $lib_dir = _repo_path('lib');
my $hits    = _unguarded_dollar_question_hits($lib_dir);

my @new_hits   = sort grep { !$BASELINE{$_} } keys %$hits;
my @stale_base = sort grep { !$hits->{$_} } keys %BASELINE;

is( scalar(@new_hits), 0,
    'no sub outside the DD-597 baseline reads $? without a preceding local $?; guard' )
  or diag( "New unguarded \$? use(s) not in the DD-611 baseline:\n" . join( "\n", map {"  $_"} @new_hits ) );

is( scalar(@stale_base), 0,
    'every DD-597 baseline entry still reproduces (a fix must shrink this test\'s baseline, not leave it stale)' )
  or diag( "Baseline entries the sweep no longer finds (fixed - remove from t/159's \%BASELINE):\n"
      . join( "\n", map {"  $_"} @stale_base ) );

done_testing;

__END__

=head1 NAME

t/159-dollar-question-guard-sweep.t - catch a new sub reading $? without a
local $?; guard

=head1 PURPOSE

Sweeps every sub under C<lib/> for a read of the global C<$?> with no
preceding C<local $?;> guard in its own body, and compares the result against
an explicit baseline of DD-597's still-open findings, so this specific bug
class (DD-585/589-593/597: a query helper's own subprocess call leaves C<$?>
mutated for whatever the caller reads next) cannot regress silently, and
cannot be "fixed" by simply deleting the guard without also touching this
baseline.

=head1 WHY IT EXISTS

DD-597 found 25 more instances of the same bug DD-585/589-593 already fixed
six times, using a one-off sweep script that existed only in C</tmp> and ran
exactly once. Nothing stopped a twenty-sixth instance from shipping the next
day. This test makes the sweep a standing part of C<prove -lr t> instead of a
manual step someone has to remember to repeat. It intentionally does not
demand the baseline be empty: DD-597 itself is a separate, already-open
ticket, and gating this check on that ticket landing first would mean the
regression-prevention half of the fix (a NEW unguarded sub failing the
suite) ships only once someone else's unrelated ticket closes. The baseline
is DD-597's own findings by name, so fixing one there requires shrinking it
here - a fix that leaves a stale entry behind fails this test exactly as
loudly as a genuinely new, unguarded sub would.

=head1 WHEN TO USE

Every suite run. Also read this file's C<%BASELINE> whenever DD-597 (or any
future sub in this shape) is fixed - the fix is incomplete until the fixed
entry is removed here, and this test fails loudly on a stale entry to make
that unmissable.

=head1 HOW TO USE

  PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/159-dollar-question-guard-sweep.t

=head1 WHAT USES IT

The suite, through C<prove -lr t>, and therefore CI. Its subject is every
C<.pm> file under C<lib/>.

=head1 EXAMPLES

To watch it fail on a regression, add a new sub anywhere under C<lib/> that
calls C<system()> and later reads C<$?> with no C<local $?;> guard, then
rerun - the new sub is named in the diagnostic. To watch it fail on a stale
baseline, fix any one of DD-597's 25 listed subs without removing its entry
from C<%BASELINE> here.

=cut
