#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Basename qw(dirname);
use File::Spec;

# purpose: strip Perl comments from one source line so a source scan cannot be
#          tripped, or satisfied, by prose ABOUT the code.
# input:   $line - one line of Perl source.
# output:  the line with a trailing # comment removed, quotes respected.
sub strip_comment {
    my ($line) = @_;
    my $out    = '';
    my $quote  = '';
    my @chars  = split //, $line;
    for my $i ( 0 .. $#chars ) {
        my $c = $chars[$i];
        my $prev = $i > 0 ? $chars[ $i - 1 ] : '';
        if ( $quote ne '' ) {
            $out .= $c;
            $quote = '' if $c eq $quote && $prev ne '\\';
            next;
        }
        if ( $c eq q{"} || $c eq q{'} ) { $quote = $c; $out .= $c; next; }
        last if $c eq '#' && $prev ne '$';
        $out .= $c;
    }
    return $out;
}

# purpose: decide whether an octal mode takes read or write away from the owner,
#          which is the only case in which a denial can be asserted.
# input:   $mode - a four-character octal string such as '0000' or '0644'.
# output:  a short label ('read', 'write', 'read+write') or empty string.
sub owner_loses {
    my ($mode)  = @_;
    my $owner   = substr $mode, 1, 1;
    my @lost;
    push @lost, 'read'  if !( $owner & 4 );
    push @lost, 'write' if !( $owner & 2 );
    return join '+', @lost;
}

# purpose: report every place a test removes the owner's access and then asserts
#          on the resulting denial WITHOUT probing that a denial is observable.
# input:   $path - a test file to scan.
# output:  a list of hashrefs { line, mode, target, lost }.
sub unguarded_denial_sites {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my @lines = map { strip_comment($_) } <$fh>;
    close $fh or die "Unable to close $path: $!";

    my @findings;
    for my $i ( 0 .. $#lines ) {
        my ( $mode, $target ) = $lines[$i] =~ /chmod \s* \(? \s* (0[0-7]{3}) \s* , \s* (\$\w+)/x
          or next;
        my $lost = owner_loses($mode) or next;

        # If the chmod sits inside a SKIP block, the SKIP block IS the span - a
        # skip applies to the whole block, and the mode is often restored partway
        # through it so that cleanup runs on the skip path. Cutting the span at
        # the restore put the probe's own skip outside it and reported guarded
        # code as unguarded.
        my ( $start, $end );
        my $d = 0;
        for ( my $j = $i ; $j >= 0 ; $j-- ) {
            $d += ( $lines[$j] =~ tr/}// ) - ( $lines[$j] =~ tr/{// );
            if ( $d < 0 && $lines[$j] =~ /^\s*SKIP \s* : \s* \{/x ) { $start = $j; last }
            last if $d < -1;
        }
        if ( defined $start ) {
            my $bd = 0;
            for my $j ( $start .. $#lines ) {
                $bd += ( $lines[$j] =~ tr/{// ) - ( $lines[$j] =~ tr/}// );
                if ( $bd == 0 && $j > $start ) { $end = $j; last }
            }
            $end //= $#lines;
        }
        else {
            $start = $i;
            my $depth = 0;
            $end = $#lines;
            for my $j ( $i + 1 .. $#lines ) {
                my $l = $lines[$j];
                if ( $l =~ /chmod \s* \(? \s* 0[0-7]{3} \s* , \s* \Q$target\E/x ) { $end = $j - 1; last }
                $depth += ( $l =~ tr/{// ) - ( $l =~ tr/}// );
                if ( $depth < 0 ) { $end = $j; last }
            }
        }

        my $span = join "\n", @lines[ $start .. $end ];

        # The span must exercise the denial, and there are two shapes. Some files
        # assert inside it; others capture the failure with eval and deliberately
        # restore the mode BEFORE asserting, so cleanup is safe whatever the
        # assertion does. Looking only for an assertion misses the second shape
        # entirely - it missed six of the sixteen files measured as root-caused.
        next
          if $span !~ /\b(?:ok|is|isnt|like|unlike|cmp_ok|is_deeply|\w+_like|dies\w*|lives\w*|throws\w*)\s*\(/
          && $span !~ /\beval\s*[{(]/;
        # An ACCESS-CHECKED probe only. A bare -r/-w/-x does not qualify: Perl's
        # filetest operators are mode-bit arithmetic and special-case uid 0, so
        # they answer true for root on a mode-0000 file even where the operation
        # is genuinely denied. Measured 2026-09-02 - root with DAC_OVERRIDE
        # dropped: -r true, open denied. Accepting -r would let a guard skip an
        # assertion that was about to run and pass.
        # Accept ONLY a probe tied to a real attempt. A bare -r/-w/-x never
        # qualifies: filetest operators are mode-bit arithmetic and answer true
        # for uid 0 whatever the mode, so they cannot see a dropped capability.
        next if $span =~ /\buse \s+ filetest \s+ ['"]access['"]/x;

        # skip ... if open(...)
        next if $span =~ /\bskip\b [^\n]* \bif \s+ (?:open|opendir|sysopen)\b/x;

        # if ( open ... ) { ... skip ... }
        next if $span =~ /\bif \s* \( \s* (?:open|opendir|sysopen)\b .*? \bskip\b/xs;

        # my $can = open(...) ? ... : 0;  ...  skip ... if $can;
        # The attempt's result is carried in a variable because the mode usually
        # has to be restored on the skip path too.
        if ( my ($var) = $span =~ /\$(\w+) \s* = \s* (?:open|opendir|sysopen) \b/x ) {
            # The condition may sit on the next line - `skip '...', 3\n  if !$var;`
            # is idiomatic when the message is long, so this must not be
            # line-anchored.
            next if $span =~ /\bskip\b .{0,200}? \bif \b .{0,80}? \$\Q$var\E\b/xs;
        }

        push @findings, { line => $i + 1, mode => $mode, target => $target, lost => $lost };
    }
    return @findings;
}

my $test_dir = dirname( File::Spec->rel2abs(__FILE__) );
opendir my $dh, $test_dir or die "Unable to read $test_dir: $!";
my @tests = sort grep { /\.t\z/ && $_ ne '168-permission-assertion-guards.t' } readdir $dh;
closedir $dh or die "Unable to close $test_dir: $!";

ok( scalar @tests > 100, 'the scan has a non-empty subject to discriminate' )
  or BAIL_OUT('no test files found - this is could-not-look, not a clean result');

my %offenders;
for my $t (@tests) {
    my @f = unguarded_denial_sites( File::Spec->catfile( $test_dir, $t ) );
    $offenders{$t} = \@f if @f;
}

my $total = 0;
$total += scalar @{ $offenders{$_} } for keys %offenders;

is( $total, 0, 'every assertion on a permission denial is guarded by a probe that the denial is observable' )
  or diag(
    "Unguarded denial sites - each removes the owner's access and then asserts,\n"
      . "with nothing checking that the running process can actually be denied.\n"
      . "Under uid 0 with CAP_DAC_OVERRIDE these assertions cannot pass.\n"
      . "Guard with the probe form already used in t/103, t/115 and t/95:\n"
      . "    chmod 0000, \$file or skip 'chmod not honored on this filesystem', 1;\n"
      . "    skip 'running as root defeats the unreadable-file open failure', 1 if -r \$file;\n\n"
      . join( "\n",
        map { my $t = $_; map { sprintf '  %s:%d  chmod %s %s  (owner loses %s)', $t, $_->{line}, $_->{mode}, $_->{target}, $_->{lost} } @{ $offenders{$t} } }
          sort keys %offenders )
  );

done_testing();

__END__

=head1 NAME

t/168-permission-assertion-guards.t - assert that permission-denial tests can actually fail

=head1 PURPOSE

Find every place in the test suite that removes the owner's read or write access
and then asserts on the resulting denial, without first checking that the running
process is capable of being denied.

=head1 WHY IT EXISTS

A process holding CAP_DAC_OVERRIDE - which is in Docker's default retained set,
and which root holds unless it is explicitly dropped - bypasses discretionary
access control entirely. A test that chmods a file to 0000 and asserts the open
fails is then asserting something that cannot happen, and it fails for a reason
that has nothing to do with the product.

Measured on 2026-09-02: the suite run as uid 0 inside the project image failed 29
files; the same files as uid 1000 failed 13. The 16-file difference was entirely
this shape.

The guard has to probe rather than ask who the process is. C<$E<gt> == 0> is true
for a root process whose capabilities have been dropped, so an identity test
skips work that would genuinely have passed - it is correct only for as long as
nobody changes the capability set.

=head1 WHEN TO USE

It runs with the suite. Consult it directly when adding a test that asserts an
operation is refused, or when a container run reports permission failures that do
not reproduce for an unprivileged user.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/168-permission-assertion-guards.t

A failure names each unguarded site as C<file:line> with the mode and the target,
and prints the probe form to copy.

=head1 WHAT USES IT

Nothing calls it; the harness runs it. It reads every other C<.t> file in C<t/>
and excludes only itself.

=head1 EXAMPLES

Guarded, and therefore accepted:

    chmod 0000, $file or skip 'chmod not honored on this filesystem', 1;
    skip 'running as root defeats the unreadable-file open failure', 1 if -r $file;
    like( ( eval { $runner->loop_state('x'); 1 } ? '' : $@ ), qr/Unable to read/, '...' );

Unguarded, and reported:

    chmod 0000, $file or die "Unable to chmod $file: $!";
    like( ( eval { $runner->loop_state('x'); 1 } ? '' : $@ ), qr/Unable to read/, '...' );

=cut
