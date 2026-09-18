# Per-skill Go module resolution

`Platform.pm`'s `_exec_java_source`'s sibling, `_exec_go_source`, runs
`go run <path>` with no directory change, so it inherits whatever working
directory the `dashboard`/`d2` command was launched from. Go's `go.mod`
discovery walks up from the current working directory, not from the source
file's own path - so a `cli/foo.go` living inside a skill with its own
`go.mod` only gets that skill's declared dependencies if the caller happens
to already be inside that directory tree. Run from anywhere else, the
skill's `go.mod` is missed entirely and `go run` falls back to
no-module/GOPATH-style resolution, silently dropping the skill's
dependencies.

## The mechanism

`_exec_go_source` passes Go's native `-C <dir>` flag (available since Go
1.20) instead of a bare `go run <path>`:

```
go run -C <skill's own directory> <path>
```

`-C` changes directory before running, so `go.mod` discovery correctly
starts from the skill's own folder regardless of the caller's cwd. No new
dependency-discovery mechanism is invented; Go's own module system already
does per-directory isolation natively - this only points it at the right
directory.

Verified live on this host (Go 1.26.2, 2026-09-09):
`go run -C /tmp/godctest main.go` printed the program's output correctly
from a caller cwd outside that directory, confirming the flag exists and
behaves as documented.

## What does not change

A skill with no `go.mod` anywhere in its tree continues to run exactly as
today - `-C` only changes where Go looks for a module file; it does not
require one to exist.

## Per-layer module and build CACHE isolation (DD-951)

`-C` (DD-825, above) solves *finding* the right `go.mod` - it does not
solve *where downloaded dependencies and build artifacts land*. Without
further changes, every skill's `go run` still shares one global
`GOMODCACHE`/`GOCACHE` (`$GOPATH/pkg/mod` and Go's default build cache),
exactly the shape DD-824 fixed for Python's global `pip --user` and DD-823
fixed for Java's shared local repository - two skills declaring different
(or conflicting) versions of the same Go module would silently share one
cache entry.

`_exec_go_source` now also sets `GOMODCACHE`/`GOCACHE` to a directory
under the skill layer's own `local/go-cache/` (mirroring DD-824's
`local/venv/` convention) whenever a sibling `go.mod` is found via the
same directory Walk `-C` already resolves to. A skill with no `go.mod`
is unaffected - the env vars are only set when a real module file was
found, so the pre-DD-951 no-module fallback behavior is unchanged.

```
GOMODCACHE=<skill layer>/local/go-cache/mod \
GOCACHE=<skill layer>/local/go-cache/build \
go run -C <skill's own directory> <path>
```

No new manifest file is introduced - `go.mod` itself is both the
dependency declaration Go already reads and the trigger for isolation,
so there is nothing equivalent to Java's `config/pom.xml` subdirectory
convention or Python's separate install step to wire into the
`aptfile`/`apkfile`/`dnfile`/`cpanfile`/`Makefile`/`ddfile` install
order - Go resolves and downloads its own dependencies lazily, on the
first `go run` of each skill, the same way it already did before this
change.

## Origin

Michael asked for the same per-skill dependency isolation treatment given to
Java (DD-823) and Python (DD-824) to be applied to Go. Approved 2026-09-08
("Yes, do it"). The first pass (DD-825) was framed as "the smallest of
the three sibling tickets" - one flag added to one invocation - because
it solved discovery only. DD-951 completed the isolation Java and Python
both already had: per-layer cache directories, not just per-layer module
discovery.
