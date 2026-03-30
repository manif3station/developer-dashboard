# Update And Release

## Local Update

Run:

```bash
perl -Ilib bin/dashboard update
```

This executes ordered scripts from `updates/`:

1. bootstrap runtime config and starter pages
2. refresh Perl dependencies with `cpanm --installdeps .`
3. write shell bootstrap and append it to the user shell rc file if needed

The update manager also stops running collectors before updates and restarts them afterward.

## Local Usage

Initialize runtime state:

```bash
perl -Ilib bin/dashboard init
```

Serve the local app in the background:

```bash
perl -Ilib bin/dashboard serve
```

The root path now opens the free-form bookmark editor directly, and `/apps` redirects to `/app/index`.

Create a helper login user:

```bash
perl -Ilib bin/dashboard auth add-user <username> <password>
```

Remove a helper login user:

```bash
perl -Ilib bin/dashboard auth remove-user helper
```

Render shell bootstrap:

```bash
perl -Ilib bin/dashboard shell bash
```

Refresh generic built-in indicators:

```bash
perl -Ilib bin/dashboard indicator refresh-core
```

Inspect collector state:

```bash
perl -Ilib bin/dashboard collector inspect example.collector
```

Render prompt in extended colored mode:

```bash
perl -Ilib bin/dashboard ps1 --jobs 1 --mode extended --color
```

Stop the web service and managed collector loops:

```bash
perl -Ilib bin/dashboard stop
```

Restart the web service and configured collector loops:

```bash
perl -Ilib bin/dashboard restart
```

Customize runtime locations:

```bash
export DEVELOPER_DASHBOARD_BOOKMARKS="$HOME/my-dd-pages"
export DEVELOPER_DASHBOARD_CONFIGS="$HOME/my-dd-config"
export DEVELOPER_DASHBOARD_STARTUP="$HOME/my-dd-startup"
export DEVELOPER_DASHBOARD_CHECKERS="docker.health:repo.status"
```

Access semantics:

- `http://127.0.0.1:7890/` is trusted as local admin
- `http://localhost:7890/` is helper access and requires login
- remote or non-canonical host access also requires login

The default bind is `0.0.0.0:7890`, so the service is reachable on local and VPN interfaces unless the host firewall blocks it.

Process management does not trust pid files alone. The runtime validates managed web and collector processes by environment marker or process title, and uses a `pkill`-style scan fallback when pid state is stale.

Security baseline:

- helper passwords must be at least 8 characters long
- helper sessions are remote-bound and expire automatically
- the local server adds CSP, frame-deny, nosniff, no-referrer, and no-store headers

The extension layer now includes:

- JSON plugin packs in the global or repo-local plugins directory
- provider pages resolved through the page resolver
- action execution through the page action runner
- project-aware Docker Compose resolution through `dashboard docker compose`

## Release To PAUSE

The GitHub workflow:

- `.github/workflows/release-cpan.yml`

builds the release using Dist::Zilla:

```bash
dzil build
```

and uploads the resulting tarball to PAUSE using:

- `PAUSE_USER`
- `PAUSE_PASS`

stored as GitHub Actions secrets.

Runtime JSON handling is implemented with `JSON::XS`, including the shell bootstrap helper used by `dashboard shell bash`.

Command-output capture is implemented with `Capture::Tiny` `capture`, with exit codes returned from the capture block. The core runtime does not currently make outbound HTTP client requests.

## Coverage Verification

Before release, verify the library coverage target:

```bash
eval "$(perl -I ~/perl5/lib/perl5 -Mlocal::lib=~/perl5)"
cover -delete
HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t
cover -report text -select_re '^lib/' -coverage statement -coverage subroutine
```

Release quality requires a reviewed coverage report for `lib/` alongside a green test suite.
