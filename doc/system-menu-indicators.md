# System menu indicator configuration

`Developer::Dashboard::SystemMenu->items_for_platform` is a deterministic
configuration projection. It does not start a native menu or a helper process.

The method accepts the merged dashboard configuration, an array of current
indicator records, and a platform key. For each configured indicator it reads
the matching opt-in selector from `indicator`:

1. `macos`
2. `windows`
3. `ubuntu`

Only JSON booleans or scalar `0` and `1` are accepted when a selector is
defined. Missing and false selectors disable the entry. Invalid supported
selectors fail visibly, including selectors for platforms other than the
requested platform. The result keeps configuration order and includes only
enabled indicators that have a current state, represented by their name and
icon. Other platform names return an empty list.

Example configuration:

```json
{
  "indicators": [
    { "name": "build", "indicator": { "macos": true, "windows": true } },
    { "name": "tests", "indicator": { "ubuntu": true } }
  ]
}
```

The projection is independent of AppKit, Windows notification-area APIs, and
GTK. The native System::Menu adapter starts the platform helper in a controlled
GoRoutine worker and forwards configured items and state changes. On Ubuntu,
the helper uses Ayatana AppIndicator3 and a GTK menu; rendered status icons are
kept in a private temporary icon-theme directory and removed when the helper
shuts down. Building from source requires the Ayatana AppIndicator3 and GTK3
development packages, and runtime requires a desktop session with AppIndicator
support. The helper reports a clear error when no desktop session is available.
Source-contract and compile tests do not prove that a desktop shell visibly
displayed the menu.

The focused test runs inside the project development container:

```sh
  d2 docker compose exec --workdir /work dev prove -lv t/239-system-menu-config.t t/241-system-menu-runner.t t/242-system-menu-bundle.t t/243-system-menu-linux-indicator-api.t

The development image installs `libayatana-appindicator3-dev` and builds the
Linux helper with deprecated-API declarations treated as errors.
```
