# d2's self-compiled binary and the `$Bin` resolution trap (DD-924)

## The defect

`bin/d2`'s self-compile hook (`_maybe_exec_self_compiled_d2`, DD-882) finds a
cached PAX-compiled binary matching d2's own source MD5 and execs it
directly. That compiled binary is the whole packed body of `bin/d2`,
including its top-of-file computation of the sibling `dashboard` path:

```perl
my $dashboard = File::Spec->catfile( $Bin, 'dashboard' );
```

`$Bin` comes from `FindBin`, whose own documentation says it resolves to
"path to bin directory from where script was invoked" — i.e. derived from
the *running script's own invocation path* (`$0`), not from where its
*source* originally lived. For an interpreted `perl bin/d2 ...` run, that is
the real `bin/` directory and the computation is correct. For a **compiled**
binary, `$0` is the compiled binary's own path — wherever PaxCache physically
stores it (`~/.developer-dashboard/cache/pax/<md5>.pax`) — so `$Bin` resolves
there instead, and the fallback looks for a file literally named `dashboard`
inside a directory that only ever holds md5-named `.pax` files. It fails with
`Can't open perl script ".../cache/pax/dashboard": No such file or
directory`, for every invocation, until the stale cache entry is evicted or
worked around.

## Why the fix bakes the path into an env var rather than recomputing it

The whole source file — including this computation — is what PAX embeds
verbatim into the compiled binary, so there is no way to make the *compiled*
binary's own copy of this line compute correctly by editing only that line:
whatever expression sits there runs again, inside the compiled binary, with
`$Bin` already wrong.

The fix instead captures the correct value once, on the **first,
genuinely-interpreted run** — before any self-exec has happened, while
`$Bin` is still accurate — and passes it forward through the process
environment (`DEVELOPER_DASHBOARD_D2_DASHBOARD_PATH`), the same mechanism
this hook already uses for its `DEVELOPER_DASHBOARD_PAX_SELF_EXECED` guard.
The top-of-file computation then prefers that env var over a fresh (and,
inside the compiled binary, wrong) `$Bin`-based recomputation:

```perl
my $dashboard = $ENV{DEVELOPER_DASHBOARD_D2_DASHBOARD_PATH}
    || File::Spec->catfile( $Bin, 'dashboard' );
```

Both env vars are deleted on the no-cache-hit fallthrough path so neither
leaks into whatever `dashboard` itself execs into.

## Why the existing test (`t/184`) never caught this

`t/184-d2-self-compile.t` originally seeded a hand-written sentinel script as
the "cached binary" — `print "...SENTINEL...\n"` — to test that d2
*dispatches* to a cache hit correctly. That sentinel never runs any of d2's
own compiled body, so it structurally cannot exercise the compiled binary's
internal `$Bin`-dependent fallback line, which is exactly where the defect
lives. DD-924 added a second block that builds a **real** `pax`-compiled `d2`
binary (via `share/private-cli/pax build`, the same mechanism
`t/183-pax-cli-build-run-contract.t` uses) and seeds *that* into the cache,
so the compiled binary's actual internal exec-into-dashboard fallback is
genuinely exercised.

## The general lesson

A self-compile dispatch test and a self-compiled-binary-behavior test are
different claims. Seeding a fake binary proves only the dispatch decision; it
says nothing about what the real compiled artifact does once it starts
running its own body. Any test that stands in for "the compiled output
behaves correctly" needs to run compiled output, not a stand-in for it.

## A second, related gap: dispatching TO a compiled sibling (DD-1017)

The fix above gets the *path* to `$dashboard` right even inside a compiled
`d2` binary. It says nothing about *what kind of file* `$dashboard` is once
resolved — and the line that actually uses it,

```perl
exec { $^X } $^X, $dashboard, @ARGV;
```

unconditionally routes through the perl interpreter (`$^X`), assuming
`$dashboard` is always Perl source. That assumption breaks under
`DDE-006`'s multi-platform PAX CI goal: a user who downloads BOTH a
compiled `d2` and a compiled `dashboard` binary, with no Perl installed at
all, gets `perl` invoked against a compiled ELF/PE/Mach-O file — which
cannot parse it as source. Reproduced live, 2026-09-22: a compiled `d2`
binary crashed trying to run a compiled `dashboard` binary this way.

The fix (DD-1017) is a small addition in the same spirit as the `$Bin`
fix above — detect the two cases and dispatch differently, rather than
assuming one shape everywhere:

```perl
my $dashboard_is_compiled = do {
    open my $fh, '<:raw', $dashboard or die "cannot check $dashboard: $!";
    my $magic;
    read $fh, $magic, 2;
    close $fh;
    !defined($magic) || $magic ne '#!';
};

if ($dashboard_is_compiled) {
    exec { $dashboard } $dashboard, @ARGV;
}
else {
    exec { $^X } $^X, $dashboard, @ARGV;
}
```

A Perl script always opens with a `#!` shebang; a PAX-compiled binary
never does. This keeps the *existing* interpreted path (and
`t/49-d2-entrypoint.t`'s exact regex assertions against it) completely
unchanged, and adds the compiled-binary case as a genuinely new branch
rather than a modification of the old one.
