# t/40-install-bootstrap.t's PATH mocking must hide, not merely shadow

`t/40-install-bootstrap.t` exercises `install.sh` end to end by running it as
a real subprocess against a directory of fake tool scripts (`curl`, `cpanm`,
`apk`, `dnf`, `perlbrew`, ...), one fake script per platform/tool combination
under test. Every fixture builds the subprocess's `PATH` as:

```perl
{ key => 'PATH', value => $fake_bin . ':' . ( $ENV{PATH} || '' ) }
```

i.e. the fake tool directory is **prepended** to the real, inherited `PATH`
- never a replacement for it. That is deliberate and correct for every tool
the fixture *shadows*: since `$fake_bin` comes first, `command -v <tool>`
finds the fake script before any real one further down `PATH`, regardless
of what else is installed on the machine running the test.

## The gap: a tool that must appear ABSENT cannot be shadowed

Several fixtures test what `install.sh` does when a tool is **not yet
installed** - most importantly the `fake_perlbrew_on_path => 0` combination,
which exercises `install.sh`'s own `cpanm`-based perlbrew-bootstrap branch
(`bootstrap_perlbrew_perl`'s `if ! command -v perlbrew` guard). That fixture
deliberately places no `perlbrew` script in `$fake_bin`, because the whole
point is to make `command -v perlbrew` report **absent**.

Shadowing cannot produce "absent" - it can only produce "found earlier".
Omitting a fake script from `$fake_bin` does not make a tool absent; it just
stops hiding whatever the same name resolves to further down the inherited
`PATH`. On any host with the real tool actually installed system-wide (e.g.
the `perlbrew` Debian/Ubuntu apt package, which installs to `/bin/perlbrew`
via `/usr/share/perl5/App/perlbrew.pm`), `command -v perlbrew` still
succeeds - just against the real binary instead of a fake one. `install.sh`
then takes the "already installed" branch for real, invokes the real tool
against the sandboxed fixture environment, and fails on whatever real
network/mirror/filesystem assumption that tool makes that the fixture never
intended to satisfy.

This is what DD-851 diagnosed and fixed: tests asserting the cpanm-bootstrap
branch failed deterministically on any host with the real `perlbrew` apt
package installed, because the real system perlbrew was invoked instead of
the intended fake one, and failed on its own real mirror-index resolution
rather than on anything install.sh got wrong.

## The fix: shadow the directory, not the command

`_path_hiding_command($command)` in `t/40-install-bootstrap.t` walks each
directory on the inherited `$ENV{PATH}` and, for any directory that contains
a real executable by the given name, substitutes a throwaway directory
holding symlinks to every *other* entry in that directory (built by
`_shadow_dir_without`). The named command is the one entry never symlinked,
so `command -v <command>` genuinely finds nothing there, while every other
real tool that directory provides (`dirname`, `basename`, `sh`, and
whatever else a fixture doesn't fake) stays reachable exactly as before.

Simply dropping the whole directory from `PATH` was tried first and is
**wrong**: `/bin` on this project's dev hosts is also where core,
unmocked-and-never-going-to-be-mocked utilities like `dirname` and
`basename` live, and `install.sh` calls them directly. Removing the
directory entirely breaks the subprocess in a different, more confusing way
(`install.sh: 6: dirname: not found`) before it ever reaches the code path
under test.

## Reviewing a change against this

- **A fixture that wants to simulate "not installed" must genuinely hide the
  real tool, not merely decline to shadow it with a fake one.** Prepending a
  fake directory to the real `PATH` shadows; it does not hide. Whenever a
  new `fake_*_on_path => 0`-style fixture is added to this test, check
  whether the real tool it is trying to simulate as absent might exist on
  some dev host's real `PATH` - if the tool is a common package-manager
  install (a system Perl/Python/Node tool, a common CLI), assume yes and use
  `_path_hiding_command`.
- **Never strip a whole PATH directory to hide one command inside it.** A
  real directory on `PATH` almost always also carries unrelated tools this
  test still needs unmocked. Shadow the directory's *other* contents instead.
