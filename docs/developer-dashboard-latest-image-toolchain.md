# The `developer-dashboard:latest` image's toolchain

## Where it is built

`test_by_michael/Dockerfile` is the build source for the `developer-dashboard:latest`
image produced by `d2 docker.images.build` - not `.clusterfuzzlite/Dockerfile`, which
builds a separate, unrelated ClusterFuzzLite fuzzing image. `test_by_michael/Dockerfile`
pins a real base (`ubuntu:26.04`, per DD-761, deliberately not `FROM
developer-dashboard:latest` itself, so every build starts from a genuinely clean layer
rather than accumulating on top of the previous build), installs the distribution's own
tarball via `cpanm`, and runs a build-time freshness check against `cpanfile`.

## It is a minimal image, and its tooling gaps surface one at a time

The image installs only what the base `curl vim iproute2 lsof` line names, plus whatever
each incident has since added. That is deliberate - a minimal image is smaller and
faster to build - but it means any tool a skill or test needs and the image does not
carry surfaces as a runtime failure inside the container rather than as a build-time
decision. Found and fixed this way so far:

- **DD-827**: `ss`/`lsof` were absent, so `t/09`'s listener-pid test fell through to its
  empty fallback path. Fixed by adding them to the `apt-get install` line.
- **DD-829**: no `go` binary at all, so `cli/*.go` E2E/ATDD work had no container to
  verify against.
- **DD-830**: `python3` ships in the base image, but Debian/Ubuntu split `pip` out of
  the base `python3` package - `python3 -m pip` failed with `No module named pip`, so
  any skill with a `requirements.txt` could not install at all. `python3-pip` alone was
  not enough to fix it: DD-824's real install path creates a per-skill venv FIRST
  (`python3 -m venv`), and `python3-venv` was ALSO missing - venv creation failed with
  "ensurepip is not available", the code fell back to a direct `pip install --user`,
  and Debian's PEP-668 externally-managed-environment guard refused that too. Fixed by
  adding **both** `python3-pip` and `python3-venv` to the `apt-get install` line; a venv's
  own pip is exempt from the PEP-668 guard, which only blocks installing into the system
  interpreter.

## The pattern for the next one

When a skill or test needs a tool the image does not have: reproduce it live first
(`docker run --rm developer-dashboard:latest <the failing command>`), confirm
`test_by_michael/Dockerfile` is still the build source (it may move - check for a
`DD-761`-style comment naming it explicitly), add the tool to the existing `apt-get
install` line rather than a new `RUN` layer (keeps the image's layer count stable), and
rebuild with `d2 docker.images.build` to verify the fix live rather than trusting the
Dockerfile diff alone.
