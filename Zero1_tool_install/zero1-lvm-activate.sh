#!/usr/bin/env bash
set -uo pipefail

# Activate all discovered LVM volume groups before FnOS trim_init starts.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
  printf '[zero1-lvm-activate] %s\n' "$*"
}

VGCHANGE="$(command -v vgchange 2>/dev/null || true)"
if [[ -z "$VGCHANGE" ]]; then
  log "ERROR: vgchange is unavailable; LVM activation was not attempted."
  exit 1
fi

# Let udev finish publishing block devices before refreshing the LVM cache.
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle --timeout=15 || log "WARNING: udev settle timed out; continuing with LVM activation."
fi

if command -v pvscan >/dev/null 2>&1; then
  pvscan --cache || log "WARNING: pvscan cache refresh failed; vgchange will perform its own scan."
fi

log "Activating all detected LVM volume groups..."
if "$VGCHANGE" --activate y; then
  log "LVM activation completed."
else
  log "ERROR: LVM activation failed; trim_init will still be allowed to continue."
  exit 1
fi
