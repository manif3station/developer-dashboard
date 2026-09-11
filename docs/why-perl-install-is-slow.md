# Why installing developer-dashboard is slow, and what genuinely helps

`install.sh` bootstraps the project by running `cpanm` against `cpanfile`'s
~30 declared runtime dependencies. Most of the wall-clock time users see is
spent inside `cpanm`, compiling those dependencies from source — this page
records what was actually checked before concluding there is no quick,
safe fix, so the next person doesn't have to re-derive it.

## What's already done

`install.sh` already invokes `cpanm` with `--notest` on every install (both
the bootstrap of `local::lib`/`App::cpanminus`/`File::ShareDir::Install`
and the main dependency install). That is the single biggest lever `cpanm`
offers — skipping every dependency's own test suite — and it is already in
place.

## What was checked and does NOT apply

**cpanm has no parallel-install flag.** Checked directly against the
installed version:

```
$ cpanm --version
cpanm (App::cpanminus) version 1.7049
$ cpanm -h
  -v,--verbose  -q,--quiet  --interactive  -f,--force  -n,--notest
  --test-only  -S,--sudo  --installdeps  --showdeps  --reinstall
  --mirror  --mirror-only  -M,--from  --prompt  -l,--local-lib
  -L,--local-lib-contained  --self-contained  --auto-cleanup  ...
```

No `-j`/`--jobs`/`--parallel` option exists in this cpanm release. There is
nothing to add to `install.sh` here.

**Precompiled Debian/Ubuntu packages exist for several deps, but their
versions are below this project's declared `cpanfile` floors** — so
substituting `apt install lib*-perl` for `cpanm ModuleName` is not a safe
drop-in:

| module | cpanfile floor | apt candidate (Ubuntu 24.04) | usable? |
|---|---|---|---|
| YAML::XS | 0.903.0 | `libyaml-libyaml-perl` 0.89+ds | **no** - below floor |
| Cpanel::JSON::XS | 4.41 | `libcpanel-json-xs-perl` 4.37 | **no** - below floor |
| Template | 3.103 | `libtemplate-perl` 2.27 | **no** - below floor |
| Plack | 1.0054 | `libplack-perl` 1.0051 | **no** - below floor |
| JSON::XS | 4.04 | `libjson-xs-perl` 4.040 | yes, but see below |
| Dancer2 | 0.206000 | `libdancer2-perl` 1.1.0+dfsg | version-scheme mismatch, unverified |

Several of this project's `cpanfile` floors were raised specifically to
close CVEs (e.g. DD-433's `HTTP::Date` 6.08 floor). Swapping any dependency
to an older, OS-packaged version without re-auditing it against
`script/cpan-audit-declared-chain` would risk silently reopening one of
those. Even the two rows that technically clear their floor are not
adopted here without that re-audit and without checking every other
declared dependency the same way — a partial substitution is worse than
none, because it looks like progress while leaving the risk unassessed.

## What the real cost is

The remaining time is genuine C-compilation of XS modules: `JSON::XS`,
`YAML::XS`, `Cpanel::JSON::XS`, `Compress::Raw::Zlib`,
`IO::Compress::Gzip`/`IO::Uncompress::Gunzip`, `Digest::MD5`, `Digest::SHA`,
`HTML::Parser`, `XML::Parser`, and `String::Compare::ConstantTime` all
build native code from `cpanm`. That is not fixable by a flag or a config
change - it is the actual work being done, once test suites are already
skipped.

## What would genuinely help, and what each costs

- **Cache a pre-built `local::lib` tree across installs** (Docker layer
  caching, or a project-provided prebuilt archive) — helps repeat installs
  and CI, not a first-time end-user install on a fresh machine. `cpanm`'s
  own `--auto-cleanup` (default 7 days) already reuses its `~/.cpanm/work`
  build cache across nearby-in-time installs on the same machine, at no
  cost to add.
- **Re-audit and raise this project's `cpanfile` floors down to match a
  usable apt version, where an apt version exists and is safe** — real
  work, needs a full `cpan-audit-declared-chain` pass per module changed,
  and needs Michael's sign-off since it touches declared runtime
  dependencies. Not bundled into this ticket (see DD-849's scope_out).
- **Nothing to change in `install.sh` itself** — it already uses the one
  flag (`--notest`) that actually helps, and there is no parallel-install
  option to add.
