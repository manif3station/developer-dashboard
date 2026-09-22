#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1 (DD-1029 root cause): `no Module;` loads Module exactly like
# `use Module;` does (Perl implements `no` as `use Module (); Module->
# unimport(...)`), so it is a real, load-bearing dependency declaration
# - but _declared_modules previously only recognized `use` and
# `require`, never `no`. This is the EXACT reason overload.pm's own
# `no overloading;` (confirmed in the real installed overload.pm
# source, lines 84/113) was never discovered as a dependency and so
# was never bundled into the standalone runtime, crashing
# 'dashboard init'/'dashboard jq' on the real published release binary
# with "Can't locate overloading.pm in @INC".
my $source = <<'PERL';
package Foo;
use strict;
no overloading;
sub bar { 1 }
PERL

my @modules = Developer::Dashboard::Pax::StandaloneImage::_declared_modules($source);
ok( ( grep { $_ eq 'overloading' } @modules ), 'no overloading; is recognized as a declared dependency' );
ok( ( grep { $_ eq 'strict' } @modules ), 'a normal use statement is still recognized (no regression)' );

# AC-2: multiple `no` pragmas, and one with a namespaced module name.
my $source2 = <<'PERL';
package Bar;
no warnings 'uninitialized';
no My::Fancy::Pragma;
PERL
my @modules2 = Developer::Dashboard::Pax::StandaloneImage::_declared_modules($source2);
ok( ( grep { $_ eq 'warnings' } @modules2 ), 'no warnings (with an argument list) is still recognized' );
ok( ( grep { $_ eq 'My::Fancy::Pragma' } @modules2 ), 'a namespaced module after no is recognized' );

# AC-3: the real installed overload.pm source, exactly as shipped,
# really does declare `no overloading;` - not a synthetic fixture.
my $real_overload_path = $INC{'overload.pm'};
if ( !$real_overload_path ) {
    # overload.pm is core and always resolvable via a %Config-free probe:
    require Config;
    for my $dir ( @Config::Config{qw(privlibexp archlibexp)} ) {
        my $candidate = "$dir/overload.pm";
        if ( -f $candidate ) { $real_overload_path = $candidate; last; }
    }
}
SKIP: {
    skip 'could not locate a real overload.pm on this host', 1 if !$real_overload_path;
    open my $fh, '<', $real_overload_path or skip "cannot read $real_overload_path: $!", 1;
    local $/;
    my $real_source = <$fh>;
    close $fh;
    my @real_modules = Developer::Dashboard::Pax::StandaloneImage::_declared_modules($real_source);
    ok( ( grep { $_ eq 'overloading' } @real_modules ), 'the REAL installed overload.pm source is confirmed to declare no overloading; and it is now discovered' );
}

done_testing();

__END__

=pod

=head1 NAME

219-standaloneimage-no-pragma-dependency.t - proves DD-1029's real root-cause fix

=head1 PURPOSE

Guards that C<_declared_modules> recognizes C<no Module;> as a real
dependency declaration, not just C<use Module;> / C<require Module;>.

=head1 WHY IT EXISTS

DD-1029 found that the real, published GitHub Release linux-amd64
binary crashes C<dashboard init> and C<dashboard jq> with C<Can't
locate overloading.pm in @INC>. Root-caused here: C<overload.pm>'s own
real source declares C<no overloading;> (confirmed at lines 84/113 of
the actual installed module) rather than C<use overloading;>. Perl
implements C<no Module;> as C<use Module (); Module-E<gt>unimport(...)>
- it genuinely loads the module - but C<_declared_modules>'s regex only
matched C<use>/C<require>, so this real, load-bearing dependency was
invisible to PAX's dependency scanner and never bundled.

=head1 WHEN TO USE

Run this file whenever C<_declared_modules> changes.

=head1 HOW TO USE

    prove -lv t/219-standaloneimage-no-pragma-dependency.t

=head1 WHAT USES IT

C<_declared_modules>'s C<no>-pragma recognition is not exercised by any
other test file in this suite.

=head1 EXAMPLES

Example 1:

    prove -lv t/219-standaloneimage-no-pragma-dependency.t

Confirm the fix is present and the real overload.pm source is covered.

=cut
