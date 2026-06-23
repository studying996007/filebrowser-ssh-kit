#!/usr/bin/env bash
# Stop filebrowser: kill the watchdog first (so it cannot restart the services we are about to stop),
# then the proxy, then filebrowser itself.
# Sends TERM and waits for a clean exit; if the process is still alive after the grace period, sends KILL.
# Reports the actual outcome — never claims success when the process is still running.
# Usage: bash stop.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/config.sh"

# Serialize against a concurrent start.sh via the same start-lock (#13): block until any in-flight start
# finishes so we don't tear down services it is mid-launch (its readiness checks would then spuriously
# fail). Best-effort — never let a lock hiccup stop us from stopping. Long-lived children close fd 8, so
# the lock frees the moment start.sh exits.
START_LOCK="${LOCK%.lock}.start.lock"
if exec 8>"$START_LOCK" 2>/dev/null; then flock 8 2>/dev/null || true; fi

stop_one() {  # $1=match string  $2=display name
  if ! PGREP -f "$1" >/dev/null 2>&1; then echo "· $2 not running"; return; fi
  PKILL -f "$1" 2>/dev/null
  for i in $(seq 1 20); do PGREP -f "$1" >/dev/null 2>&1 || break; sleep 0.1; done
  if PGREP -f "$1" >/dev/null 2>&1; then
    PKILL -9 -f "$1" 2>/dev/null; sleep 0.2
    echo "✓ $2 stopped (forced KILL)"
  else
    echo "✓ $2 stopped"
  fi
}

stop_one "$KA_MATCH" "watchdog"
stop_one "$PX_MATCH" "injection proxy"
stop_one "$FB_MATCH" "filebrowser"
echo "Done."
