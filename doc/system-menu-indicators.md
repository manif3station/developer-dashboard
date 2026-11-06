# Optional system-menu indicator configuration

Developer Dashboard core preserves per-indicator `macos`, `windows` and
`ubuntu` selectors as configuration data. They do not add a core dependency.
Without the independently installed system-menu integration, they have no
effect on the native operating-system menu; `dashboard serve` still works.

Example `config.json`:

```json
{
  "indicators": [
    { "name": "build", "indicator": { "macos": 1, "windows": 1, "ubuntu": 1 } },
    { "name": "tests", "indicator": { "macos": 0, "windows": 0, "ubuntu": 1 } }
  ]
}
```

Named indicator preferences continue to merge across configuration layers.
The browser indicator strip and `dashboard ps1` are independent of these flags.

## Independently installed integration

The external distribution should supply
`Developer::Dashboard::SystemMenu::Runner`, the menu projection,
`Developer::Dashboard::System::Menu` adapter and its native implementation.
Core no longer bundles any of these modules, native sources, executables,
or their platform build dependencies.

For an enabled selector, the private `web-foreground` runtime attempts to
load the external runner. When available, it constructs the runner with
the merged configuration, shared indicator store, and current platform,
then calls `run_with` around the foreground web server. A missing runner
is a supported no-op: only the desktop menu is absent. A runner that is
installed but fails to load is an error, not an absent integration.

Native rendering and macOS, Windows and Ubuntu build requirements belong
to the separate system-menu distribution's independent SDLC and tests.
Core installation does not require AppKit, GTK, Ayatana, or menu helpers.
