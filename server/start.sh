#!/usr/bin/env bash
# Start filebrowser (all in background, detached from the SSH session):
#   filebrowser  listens on 127.0.0.1:8090 (internal only; used by the proxy)
#   injection proxy  listens on 127.0.0.1:8080 (SSH tunnel hits here; adds a "Copy path" button to the UI)
#   watchdog  auto-restarts either process if it dies
# Usage: bash start.sh
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/config.sh"

# Self-serialize start.sh itself (#7): the kill+launch+readiness sequence below is not atomic, so two
# concurrent start.sh runs could stomp each other (both PKILL, both launch, both race the readiness checks).
# Take a non-blocking lock on a dedicated fd (8); a second concurrent run exits immediately. Every long-lived
# child we spawn closes fd 8 (config.sh launch_fb/launch_px, and the watchdog launch below) so the lock is
# released the moment THIS start.sh exits — a later restart is never blocked by its own services.
START_LOCK="${LOCK%.lock}.start.lock"
exec 8>"$START_LOCK" || exit 1
flock -n 8 || { echo "✗ Another start.sh is already running for this instance. Wait for it to finish, or run: bash $DIR/stop.sh" >&2; exit 1; }

# Kill any leftover processes first (idempotent; stop the watchdog before anything else so it cannot
# immediately restart the old services we are about to kill).
PKILL -f "$KA_MATCH" 2>/dev/null || true
# Wait for the old watchdog to actually exit — it holds the single-instance lock;
# we need it to release the lock before the new watchdog can take over.
for i in $(seq 1 30); do PGREP -f "$KA_MATCH" >/dev/null 2>&1 || break; sleep 0.1; done
PKILL -f "$PX_MATCH" 2>/dev/null || true
PKILL -f "$FB_MATCH" 2>/dev/null || true
sleep 1

# Refuse to start if the internal port is already held by a FOREIGN process. We just killed our own
# filebrowser above, so anything still on FB_PORT belongs to someone else — and the bare-TCP readiness
# probe below cannot tell our service from a stranger's. Without this guard, our filebrowser would fail
# to bind, the probe would connect to the stranger, and the proxy would forward user traffic (including
# the login POST) to a foreign service on a shared host (C1). Poll briefly so a just-killed instance has
# time to release the port before we conclude it is foreign.
free=""
for i in $(seq 1 20); do
  if (exec 3<>/dev/tcp/127.0.0.1/"$FB_PORT") 2>/dev/null; then sleep 0.1; else free=1; break; fi
done
if [ -z "$free" ]; then
  echo "✗ Port $FB_PORT (filebrowser internal) is already in use by another process. Set a different FB_PORT in .env, or stop the other process." >&2
  exit 1
fi

# Ensure the served root exists. filebrowser starts even when -r points at a missing directory, but
# every listing then errors — and the default FB_ROOT ($HOME/files) usually does not exist on a fresh
# machine, so the first browse would look broken. Best-effort: if it cannot be created (permissions),
# filebrowser still launches and surfaces its own error.
mkdir -p "$FB_ROOT" 2>/dev/null || true

# On a manual start, truncate both service logs (launch_* will append; the watchdog trims by LOG_MAX).
: > "$FB_LOG"; : > "$PX_LOG"

# 1) filebrowser -> internal port
launch_fb

# 2) Wait until it is listening (up to ~10 s); error out if it never comes up — never print a false success.
up=""
for i in $(seq 1 50); do
  if (exec 3<>/dev/tcp/127.0.0.1/"$FB_PORT") 2>/dev/null; then up=1; break; fi
  sleep 0.2
done
if [ -z "$up" ]; then
  echo "✗ filebrowser did not listen on :$FB_PORT within ~10 s. Check the log: $FB_LOG" >&2
  exit 1
fi

# 2b) Tighten the database file permissions. filebrowser creates the db group-readable (640);
#     it stores bcrypt password hashes and the JWT signing key, so restrict it to the owner only.
[ -f "$DB" ] && chmod 600 "$DB" 2>/dev/null || true

# Step 3 verifies the proxy via its X-FB-Server identity header, which requires curl. Fail fast with a
# curl-specific message rather than letting proxy_is_ours print the same error on all 30 retries and then
# misreport the (healthy) proxy as "did not come up … aiohttp missing?" (#6).
command -v curl >/dev/null 2>&1 || { echo "✗ curl is required to verify the proxy (it reads the X-FB-Server header). Install curl and re-run." >&2; exit 1; }

# 3) Injection proxy -> external port. Verify it is OUR proxy — a bare TCP check is not enough:
#    if another process or tunnel already occupies the port we would falsely declare success.
#    Instead we read the X-FB-Server identity header that proxy.py injects.
launch_px
up=""
for i in $(seq 1 30); do
  if proxy_is_ours; then up=1; break; fi
  sleep 0.2
done
if [ -z "$up" ]; then
  echo "✗ Injection proxy did not come up on :$PX_PORT within ~6 s (port already occupied? aiohttp missing?). Check the log: $PX_LOG" >&2
  exit 1
fi

# 4) Watchdog — verify it actually acquired the single-instance lock and entered the poll loop.
#    Without this check, a silent exit (e.g. lock already held by an orphan) would go unnoticed
#    and we would report success while the "auto-restart" guarantee is absent.
#    We use the KA_READY marker file written by keepalive.sh after it wins the lock.
rm -f "$KA_READY"
setsid nohup bash "$DIR/keepalive.sh" >"$KA_LOG" 2>&1 </dev/null 8>&- &
ready=""
for i in $(seq 1 $(( (FB_LOCK_WAIT + 2) * 5 ))); do
  [ -f "$KA_READY" ] && { ready=1; break; }
  sleep 0.2
done
if [ -z "$ready" ]; then
  echo "✗ Watchdog did not become ready within ~$((FB_LOCK_WAIT + 2)) s (single-instance lock held by a stale/orphan process?)." >&2
  echo "  Services are up now, but they will NOT be auto-restarted if they die. Check $KA_LOG; run bash stop.sh to clean up then restart." >&2
  exit 1
fi

echo "✓ Started: filebrowser(:$FB_PORT internal) + injection proxy(:$PX_PORT) + watchdog"
echo "  Local tunnel: ssh -L $PX_PORT:127.0.0.1:$PX_PORT myserver  ->  http://localhost:$PX_PORT  (replace 'myserver' with your SSH host alias)"
echo "  The web UI will show a 'Copy path' button in the bottom-right corner."
echo "  Logs: $FB_LOG / $PX_LOG / $KA_LOG"
