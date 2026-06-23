#!/usr/bin/env bash
# Shared config for the filebrowser SSH kit — sourced by start.sh / keepalive.sh / stop.sh.
# Ports, paths, logs, process-match strings, and launch functions are all centralized here so
# the three scripts stay consistent. To change a port or path, edit only this file.
# This file only defines variables and functions; it does not start anything, so it is safe to source.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from the repo root if present (so .env values feed the defaults below).
ENV_FILE="${FB_ENV:-$DIR/../.env}"
# tr -d '\r': strip CR so a CRLF-line-ending .env (edited on Windows) can't leave a stray carriage
# return in any value — notably FB_SERVER_ID, where a trailing CR makes aiohttp reject the X-FB-Server
# header and 500 every response, then misreport as "proxy down / aiohttp missing?" at start.sh (#1).
[ -f "$ENV_FILE" ] && { set -a; . <(tr -d '\r' < "$ENV_FILE"); set +a; }

BIN="${FB_BIN:-$HOME/.local/bin/filebrowser}"
FB_ROOT="${FB_ROOT:-$HOME/files}"
DB="${FB_DB:-$HOME/filebrowser.db}"

FB_PORT="${FB_PORT:-8090}"            # filebrowser internal port (proxy-only; not exposed directly)
PX_PORT="${PX_PORT:-8080}"            # injection-proxy port (user SSH tunnel hits this; must match client rport)
export FB_UPSTREAM_PORT="$FB_PORT"    # passed to proxy.py (it reads these two env vars; same defaults: 8090/8080)
export FB_PROXY_PORT="$PX_PORT"
# Identity label: proxy.py writes this into X-FB-Server so clients verify they reached the right machine.
# Default to THIS host's short name so two unconfigured servers don't both answer to the same id — which
# would let a client silently reuse a tunnel to the wrong server (#2). Never empty: an empty id makes
# proxy.py omit the header, which would in turn fail start.sh's own proxy identity check.
export FB_SERVER_ID="${FB_SERVER_ID:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo myserver)}"

FB_LOG="${FB_LOG:-$HOME/filebrowser.log}"
PX_LOG="${PX_LOG:-$HOME/filebrowser-proxy.log}"
KA_LOG="${KA_LOG:-$HOME/filebrowser-keepalive.log}"
LOG_MAX=$((5 * 1024 * 1024))          # truncate any single log that exceeds 5 MB to prevent crash-loops from filling $HOME
LOCK="${FB_LOCK:-$HOME/.filebrowser.lock}"  # single-instance flock lock: at most one watchdog runs at a time
KA_READY="${KA_READY:-$HOME/.filebrowser.watchdog.ready}"  # watchdog "acquired lock, now polling" marker; start.sh checks this to confirm the watchdog actually started
FB_LOCK_WAIT="${FB_LOCK_WAIT:-15}"    # max seconds to wait for the single-instance lock (lets transient orphan locks drain before giving up)
case "$FB_LOCK_WAIT" in ''|*[!0-9]*) FB_LOCK_WAIT=15;; esac   # coerce a non-integer .env value (e.g. "3.5" or "10 20") so start.sh's $(( )) arithmetic can't abort under set -e (#7)

# Path-config exports: proxy.py reads FB_PATH_ROOT / FB_PATH_MAP to inject the copy-path button and alias map.
export FB_PATH_ROOT="${FB_PATH_ROOT:-}"
export FB_PATH_MAP="${FB_PATH_MAP:-}"

# Process-match strings: tight substrings that uniquely identify each process in the command line.
# Avoids regex pitfalls (dots in $HOME/.local matching as wildcards) and prevents false positives from
# unrelated commands that merely mention the same path.
# FB_MATCH is derived from the binary's own name (+ the -r flag launch_fb always passes) so it still
# matches when FB_BIN points outside a */bin/* path; a hardcoded "bin/filebrowser" would miss such a
# process and make the watchdog relaunch filebrowser every cycle -> port-bind storm (I1).
FB_MATCH="$(basename "$BIN") -r"
PX_MATCH="python3 .*server/proxy\.py"
KA_MATCH="bash .*server/keepalive\.sh"

# Scope pgrep/pkill to the current user. On shared login nodes, other users may run identically-named
# processes — without -u we could falsely conclude our service is alive (skip restart) or kill theirs (C8).
PGREP() { pgrep -u "$(id -u)" "$@"; }
PKILL() { pkill -u "$(id -u)" "$@"; }

# PYBIN: pin to a Python that can actually 'import aiohttp'. Gotcha (hit 2026-06-20): non-interactive
# shells may resolve python3 to /usr/bin/python3 which lacks aiohttp -> proxy crashes immediately on
# ModuleNotFoundError. Probe the kit venv first, then conda environments, fall back to PATH last.
PYBIN="$(command -v python3 || echo python3)"
for _c in "$DIR/../.venv/bin/python3" "$HOME/anaconda3/bin/python3" "$HOME/miniconda3/bin/python3"; do
  if [ -x "$_c" ] && "$_c" -c 'import aiohttp' 2>/dev/null; then PYBIN="$_c"; break; fi
done

# Launch helpers: shared by start.sh and keepalive.sh so both sides call fb/proxy identically.
# Logs are appended. fd 9 (watchdog single-instance flock) AND fd 8 (start.sh's self-lock, #7) are both
# closed in each child (9>&- 8>&-): without this, long-lived fb/proxy children inherit those locks and the
# lock stays held after its holder exits -> a new watchdog could never acquire fd 9 (C7) and a later restart's
# start.sh would wrongly report "already running" on fd 8. Closing an unopened fd is a harmless no-op, so the
# same launch helpers stay correct whether called from start.sh (holds fd 8) or keepalive.sh (holds fd 9).
# --disableExec keeps filebrowser's Command Runner off regardless of stored config or binary age (it has had
# multiple RCE CVEs; default-off only since v2.33.8). The flag exists in every 2.x release (#11).
# umask 0077 in a subshell so filebrowser creates the db owner-only (600) from birth — it otherwise
# creates it group-readable (640), leaving a brief window before the chmod in start.sh (L2).
launch_fb() { ( umask 0077; setsid nohup "$BIN" -r "$FB_ROOT" -d "$DB" -a 127.0.0.1 -p "$FB_PORT" --disableExec >>"$FB_LOG" 2>&1 </dev/null 9>&- 8>&- & ); }
launch_px() { setsid nohup "$PYBIN" "$DIR/proxy.py"                                           >>"$PX_LOG" 2>&1 </dev/null 9>&- 8>&- & }

# Rotate a log file if it exceeds LOG_MAX bytes (truncate in place, keep the file open for appending).
# Always returns 0 so callers are not aborted by a failed stat or missing file.
trim_log() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ] && : > "$f"
  done
  return 0
}

# proxy_is_ours: check that :PX_PORT is OUR injection proxy, not just any listener on that port.
# We read the X-FB-Server identity header that proxy.py injects and compare it to FB_SERVER_ID.
# This prevents mistaking another user's tunnel or a stale process for our own running proxy (C9).
# Gotcha: NFS home directories can make /dev/tcp open hang for seconds before timing out — curl's
# -m 3 timeout is intentional; do not remove it. Falls back to bare TCP reachability when curl is absent.
proxy_is_ours() {
  if command -v curl >/dev/null 2>&1; then
    local id
    id="$(curl -s -m 3 -I "http://127.0.0.1:$PX_PORT/" 2>/dev/null \
          | tr -d '\r' | awk -F': *' 'tolower($1)=="x-fb-server"{print $2; exit}')"
    [ -n "$id" ] && [ "$id" = "$FB_SERVER_ID" ]
  else
    # curl is a declared prerequisite (install.sh enforces it). If it is somehow absent we cannot read the
    # identity header, so fail CLOSED rather than falling back to a bare-TCP probe that would accept ANY
    # listener (e.g. a foreign service squatting on PX_PORT) as "our proxy" (#6).
    echo "proxy_is_ours: curl not found; cannot verify the proxy identity header. Install curl." >&2
    return 1
  fi
}

# backoff_secs <fails>: how long to wait before retrying a service that has failed <fails> consecutive times.
# Healthy (0 or 1 failures) -> KA_BASE seconds. Then doubles each failure, capped at KA_CAP.
# Deterministic given its argument and KA_BASE/KA_CAP; also lets the watchdog track each service's backoff independently
# rather than coupling them (one failing service does not inflate the other's retry delay).
# Integer-overflow guard: cap the failure count at 8 before the left-shift so 1<<(f-1) stays safe (C13).
backoff_secs() {
  local f=${1:-0} base=${KA_BASE:-15} cap=${KA_CAP:-120} b
  [ "$f" -gt 8 ] && f=8                 # cap failure count to prevent integer overflow in 1<<(f-1) (C13)
  if [ "$f" -le 1 ]; then echo "$base"; return; fi
  b=$((base * (1 << (f - 1)))); [ "$b" -gt "$cap" ] && b="$cap"; echo "$b"
}

# ka_next_wake <now> <next_fb> <next_px>: seconds until the watchdog should next wake up.
# Takes the earlier of the two per-service next-check times so a healthy service keeps being polled
# at its own cadence even while the other service is in a long backoff interval.
# Minimum 1 second to avoid busy-polling.
ka_next_wake() {
  local now=$1 next=$2 d
  [ "$3" -lt "$next" ] && next=$3
  d=$((next - now)); [ "$d" -lt 1 ] && d=1; echo "$d"
}
