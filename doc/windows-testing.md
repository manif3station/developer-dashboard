# Windows Verification

## Purpose

This document defines how Developer Dashboard proves Windows compatibility
without relying on guesswork or POSIX-only assumptions.

The supported Windows target is a Strawberry Perl install with PowerShell
available. The verification flow is layered so fast tests catch regressions
before the slower VM gate runs.

## Verification Layers

1. Forced-Windows unit tests in `t/`

- locally override the platform detector so Linux CI can still exercise Windows dispatch logic
- assert `dashboard shell ps` and PowerShell prompt bootstrap output
- assert `ps` resolves to PowerShell rather than the POSIX `PS1` variable
- assert `.pl`, `.ps1`, `.cmd`, and `.bat` command argv resolution
- assert Windows `PATHEXT` lookup behavior

2. Real Strawberry Perl smoke on Windows

- run `integration/windows/run-strawberry-smoke.ps1`
- install the built tarball with `cpanm`
- verify `dashboard shell ps` and `dashboard ps1`
- verify one PowerShell-backed collector command
- verify one saved Ajax PowerShell handler through `Invoke-WebRequest`
- verify browser DOM rendering through Edge or Chrome when available

3. Full-system QEMU smoke

- boot a prepared Windows VM with `integration/windows/run-qemu-windows-smoke.sh`
- copy the built tarball into the guest
- run the same Strawberry Perl smoke inside the VM
- use this gate before claiming release-grade Windows compatibility

## Host Requirements

- `qemu-system-x86_64` for the VM gate
- a prepared Windows qcow2 image with Strawberry Perl, PowerShell, and OpenSSH
- SSH access into the guest
- a built tarball such as `Developer-Dashboard-1.45.tar.gz`

## Commands

Run the fast repo-side Windows logic coverage with:

```bash
prove -lv t/07-core-units.t t/05-cli-smoke.t
```

Run the Strawberry Perl smoke on a Windows host with:

```powershell
powershell -ExecutionPolicy Bypass -File integration/windows/run-strawberry-smoke.ps1 -Tarball C:\path\Developer-Dashboard-1.45.tar.gz
```

Run the full-system QEMU gate from a Linux host with:

```bash
WINDOWS_IMAGE=/var/lib/vm/windows-dev.qcow2 \
WINDOWS_SSH_USER=developer \
WINDOWS_SSH_KEY=~/.ssh/id_ed25519 \
TARBALL=/path/to/Developer-Dashboard-1.45.tar.gz \
integration/windows/run-qemu-windows-smoke.sh
```

## Release Rule

For Windows-targeted changes:

- the forced-Windows unit tests must pass
- the Strawberry Perl smoke must pass on a real Windows environment
- the QEMU smoke must pass before making a release-grade Windows compatibility claim
