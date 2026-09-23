# Writing tests that stay correct under root and without optional tools

## What this covers

Two classes of test assertion break silently when the suite runs somewhere
other than a developer's own non-root host: assertions that assume a
permission-denial actually happens, and assertions that assume an external
CLI tool (`ss`, `file`, `lsof`, ...) is on `PATH`. Both surfaced together in
a real container-based full-suite run (DD-1021) because the project's own
Docker dev image runs its default user as root and does not install every
tool the bare host happens to have.

## Permission assertions: attempt, don't predicate on identity

A `chmod 0000` file is not unreadable to root - root genuinely has the
capability to read it (this is real, not a `-r` stat lie: an actual
`open()` succeeds too). So any test that does something like:

```perl
wfile( $unread, "x\n", 0000 );
is( $thing->reads_it($unread)->[0], 404, 'unreadable file is rejected' );
```

is really asserting "permission enforcement exists on this filesystem for
this process", which is false under root (or any process holding
`CAP_DAC_OVERRIDE`). The wrong fix is `skip '...', 1 if $> == 0;` -
**identity is the wrong question**: a root process that has genuinely
dropped that capability would still be denied and this assertion would
wrongly skip. The right fix, already established in
`t/78-doctor-coverage.t`, is to attempt the actual operation the code
under test performs, and skip only when that attempt proves permission
enforcement doesn't apply here:

```perl
if ( open my $probe, '<', $unread ) {
    close $probe or die "...";
    skip 'this process can read a mode-0000 file, so the open failure cannot occur', 1;
}
```

This is `# uncoverable` for a stat-lie only; it is a live check of the
actual capability being relied on, not a guess based on who the process
claims to be.

## Tool-availability mocks must mock the availability check too

Code that shells out to an optional CLI conditionally - `if
(command_in_path('ss')) { ... } else { fallback }` - is common in this
project (`RuntimeManager::_listener_pids_for_port`, among others). A test
that stubs the shelling-out sub (e.g. `capture`) to return canned tool
output, but does **not** also stub the availability check, silently stops
testing anything the moment the real tool is absent on the host running
the suite: the code takes the fallback branch instead, the mock becomes
dead code, and the assertion fails for a completely different reason than
the one the test claims to cover.

```perl
local *Developer::Dashboard::RuntimeManager::command_in_path = sub {
    return 1 if $_[0] eq 'ss';
    return Developer::Dashboard::Platform::command_in_path(@_);
};
local *Developer::Dashboard::RuntimeManager::capture = sub (&) { ... };
```

Stub every gate the code checks before reaching the mocked call, not just
the call itself - otherwise the test's correctness depends on the host's
tool inventory, which is exactly the thing the mock exists to make
irrelevant.

## Where this bit us

DD-1021: `t/09-runtime-manager.t` test 202 and `t/105-web-app-coverage-2.t`
test 382 both failed inside a real root, `ss`-less, `file`-less Docker dev
container (`d2 docker compose ... dev`, `developer-dashboard:test` image) -
reproduced live, fixed using the two patterns above, re-verified green in
the same container.
