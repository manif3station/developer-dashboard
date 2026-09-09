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

## Origin

Michael asked for the same per-skill dependency isolation treatment given to
Java (DD-823) and Python (DD-824) to be applied to Go. Approved 2026-09-08
("Yes, do it"). This is the smallest of the three sibling tickets - one
flag added to one invocation. Tracked as DD-825.
