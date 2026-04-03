#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WINDOWS_IMAGE="${WINDOWS_IMAGE:-}"
WINDOWS_SSH_USER="${WINDOWS_SSH_USER:-developer}"
WINDOWS_SSH_KEY="${WINDOWS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-2222}"
WINDOWS_RAM_MB="${WINDOWS_RAM_MB:-8192}"
WINDOWS_CPU_COUNT="${WINDOWS_CPU_COUNT:-4}"
QEMU_PID=""

if [[ -z "${TARBALL:-}" ]]; then
  TARBALL="$(ls -1t "$ROOT_DIR"/Developer-Dashboard-*.tar.gz 2>/dev/null | head -n1 || true)"
fi

if [[ -z "$WINDOWS_IMAGE" ]]; then
  echo "WINDOWS_IMAGE is required and must point to a prepared Windows qcow2 image" >&2
  exit 1
fi

if [[ ! -f "$WINDOWS_IMAGE" ]]; then
  echo "Windows image does not exist: $WINDOWS_IMAGE" >&2
  exit 1
fi

if [[ -z "$TARBALL" || ! -f "$TARBALL" ]]; then
  echo "TARBALL is required and must point to a built Developer-Dashboard tarball" >&2
  exit 1
fi

cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID"
    wait "$QEMU_PID" || true
  fi
}
trap cleanup EXIT

echo "==> boot Windows QEMU guest"
qemu-system-x86_64 \
  -enable-kvm \
  -m "$WINDOWS_RAM_MB" \
  -smp "$WINDOWS_CPU_COUNT" \
  -drive "file=$WINDOWS_IMAGE,if=virtio" \
  -netdev "user,id=net0,hostfwd=tcp::${WINDOWS_SSH_PORT}-:22,hostfwd=tcp::7890-:7890" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -daemonize

QEMU_PID="$(pgrep -n -f "qemu-system-x86_64.*${WINDOWS_IMAGE//\//\\/}" || true)"

for _ in {1..60}; do
  if ssh -i "$WINDOWS_SSH_KEY" -p "$WINDOWS_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$WINDOWS_SSH_USER"@127.0.0.1 'echo ssh-ready' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "==> copy tarball and Windows smoke script into guest"
scp -i "$WINDOWS_SSH_KEY" -P "$WINDOWS_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$TARBALL" \
  "$ROOT_DIR/integration/windows/run-strawberry-smoke.ps1" \
  "$WINDOWS_SSH_USER"@127.0.0.1:/C:/Temp/

GUEST_TARBALL="C:/Temp/$(basename "$TARBALL")"

echo "==> run Strawberry Perl smoke inside guest"
ssh -i "$WINDOWS_SSH_KEY" -p "$WINDOWS_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$WINDOWS_SSH_USER"@127.0.0.1 \
  "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:/Temp/run-strawberry-smoke.ps1 -Tarball '$GUEST_TARBALL'"

echo "==> QEMU Windows smoke passed"

: <<'__END__'

=pod

=head1 NAME

run-qemu-windows-smoke.sh - boot a prepared Windows guest and run the Strawberry Perl smoke

=head1 SYNOPSIS

  WINDOWS_IMAGE=/var/lib/vm/windows-dev.qcow2 \
  WINDOWS_SSH_USER=developer \
  WINDOWS_SSH_KEY=~/.ssh/id_ed25519 \
  TARBALL=/path/to/Developer-Dashboard-1.42.tar.gz \
  integration/windows/run-qemu-windows-smoke.sh

=head1 DESCRIPTION

This host-side script boots a prepared Windows QEMU guest, forwards SSH and the
dashboard listener back to the host, copies the built tarball plus
F<integration/windows/run-strawberry-smoke.ps1> into the guest, and runs the
same Strawberry Perl smoke inside that Windows VM over SSH. The prepared image
is expected to already include Strawberry Perl, PowerShell, OpenSSH server, and
optionally Edge or Chrome for the headless DOM check.

=cut
__END__
