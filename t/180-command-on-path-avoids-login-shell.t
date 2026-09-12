#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

# purpose: pull _command_on_path's current definition straight out of
#          t/44-smart-router-two-stage.t, without sourcing the rest of that
#          file (which requires a built tarball and a live docker daemon,
#          and would fork a real container for anything else in it).
# input:   none.
# output:  the sub's source text, as a string ready to eval.
sub _extract_command_on_path_source {
    my $path = File::Spec->catfile( 't', '44-smart-router-two-stage.t' );
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Unable to close $path: $!";
    my ($sub) = $text =~ /(sub _command_on_path \{.*?\n\})/s;
    die "Unable to locate sub _command_on_path in $path\n" if !$sub;
    return $sub;
}

# purpose: build a throwaway HOME whose login-shell profile chain contains a
#          line that is valid bash but a syntax error under dash - the exact
#          shape of this host's real ~/.bashrc (an unrelated
#          `eval "$(SHELL=/bin/sh lesspipe)"` line) that made `sh -lc`
#          die before the command-v check inside it ever ran.
# input:   none.
# output:  the path of the fixture HOME directory.
sub _home_with_dash_incompatible_profile {
    my $home = tempdir( CLEANUP => 1 );
    open my $fh, '>', File::Spec->catfile( $home, '.profile' )
      or die "Unable to write .profile fixture: $!";
    print {$fh} "eval \"\$(printf '(')\"\n";
    close $fh or die "Unable to close .profile fixture: $!";
    return $home;
}

my $home = _home_with_dash_incompatible_profile();

# Confirm the fixture actually reproduces the login-shell hazard directly,
# independent of _command_on_path, so a failure below can never be blamed on
# a fixture that quietly stopped breaking dash.
{
    local $ENV{HOME} = $home;
    my $login_shell_exit = system( 'sh', '-lc', 'true' );
    isnt( $login_shell_exit, 0, 'fixture HOME genuinely breaks a dash login shell (sh -lc), matching the real ~/.bashrc lesspipe hazard' );
}

my $current_source = _extract_command_on_path_source();
like( $current_source, qr/'sh',\s*'-c',/, 'DD-853: _command_on_path no longer opens a LOGIN shell (sh -lc) that sources ~/.profile' );

{
    local $ENV{HOME} = $home;
    eval $current_source;    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    die "eval of extracted _command_on_path failed: $@" if $@;
    ok( _command_on_path('sh'), 'DD-853: a command that genuinely exists is still found even when HOME\'s login-shell profile chain is dash-broken' );
}

done_testing;
