#!/bin/bash
# Desktop Launcher - launch logic (install.command fills in __HOST__/__PORT__/__SRV_START__ when building the .app)
# Double-click the Desktop icon to run: open SSH tunnel -> auto-restart service if down -> open browser -> show "Disconnect" dialog (close = disconnect).
# Key: the tunnel is owned as a child process of this script; clicking "Disconnect" or closing the dialog kills the tunnel and releases the port (no lingering background process).
HOST="__HOST__"            # SSH host alias (e.g. myserver)
PORT="__PORT__"            # local port (browser opens localhost:PORT)
SRVID="__SRVID__"          # identity token (starts as alias): verified against X-FB-Server header to prevent reusing a tunnel to a different server
IDFILE="${HOME}/.cache/fb-launcher/${HOST}.srvid"   # persisted learned server identity for cross-session reuse (C12)
if [ -f "$IDFILE" ]; then _l="$(head -1 "$IDFILE" 2>/dev/null)"; [ -n "$_l" ] && SRVID="$_l"; fi
RPORT=8080                 # remote proxy port on server (fixed)
SRV_START="bash __SRV_START__"
NAME="${HOST} Connector"
# URL is set after the port is finalised (port may change during self-heal)

err(){ /usr/bin/osascript -e "display dialog \"$1\" with title \"$NAME\" buttons {\"OK\"} default button 1 with icon caution" >/dev/null 2>&1; exit 1; }
note(){ /usr/bin/osascript -e "display notification \"$1\" with title \"$NAME\"" >/dev/null 2>&1; }

# Check whether a port has a listener (uses bash built-in /dev/tcp, no extra deps)
listen_on(){ (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
port_open(){ listen_on "$PORT"; }                # is the currently selected port ready?
# Service health: 2xx/3xx/401/403 = up; 5xx (especially 502 from the proxy meaning filebrowser is down) = not up -> triggers remote self-heal; no connection = non-zero exit (C2)
svc_ok(){ local c; c="$(/usr/bin/curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)" || return 1; [ -n "$c" ] && [ "$c" -ge 100 ] && [ "$c" -lt 500 ]; }
# Read the X-FB-Server identity header from the service on port $1 (empty if not present). Lowercased for BSD/GNU awk compatibility.
# Uses HEAD (-I) to fetch only headers, not the full SPA body -> works within timeout on slow links; avoids false port-collision detection
server_id(){ /usr/bin/curl -s -m 4 -I "http://127.0.0.1:$1/" 2>/dev/null | tr 'A-Z' 'a-z' | /usr/bin/awk -F': *' '/^x-fb-server:/{print $2}' | tr -d '\r' | head -1; }
# Find the first local port >= $1 with no listener (used during self-heal port swap).
# Bounded to the full 65535 range; echoes 0 (never a valid port) if every port is taken, so the caller
# can report exhaustion instead of returning an untested port at the cap that the tunnel would fail to bind.
find_free_port(){
  local p=$1
  while [ "$p" -le 65535 ] && listen_on "$p"; do p=$((p+1)); done
  [ "$p" -gt 65535 ] && { echo 0; return; }
  echo "$p"
}
# Poll a probe function: returns 0 on success, non-zero on timeout. $1=function $2=max-tries $3=interval-seconds
wait_for(){ local fn=$1 n=$2 d=$3 i; for i in $(seq 1 "$n"); do "$fn" && return 0; sleep "$d"; done; return 1; }

# Immediate feedback on double-click: confirm "it registered", then push a notification at each stage (native macOS, no deps, no black window)
note "Connecting to ${HOST}..."

OWNS=0   # whether this script opened the tunnel (only then are we responsible for closing it)

# 0) Decide which local port to use. If the port is already occupied, probe the identity (X-FB-Server).
#    Match -> reuse; mismatch (another server's tunnel or an unrelated program) -> find a free port, never connect to the wrong host.
if listen_on "$PORT"; then
  WHO="$(server_id "$PORT")"
  if [ -n "$WHO" ] && [ "$(printf '%s' "$WHO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$SRVID" | tr 'A-Z' 'a-z')" ]; then
    note "Found an existing ready connection, reusing"
  else
    NEW="$(find_free_port $((PORT+1)))"
    [ "$NEW" -le 0 ] && err "No free local port is available to reach ${HOST}.\n\nClose some applications that are using local network ports, then try again."
    note "Local port ${PORT} is occupied, switching to ${NEW}"
    PORT="$NEW"
  fi
fi
URL="http://localhost:${PORT}/"

# 1) Open the tunnel if not already open. No -f: run as a background child and keep the PID so the "Disconnect" action can kill exactly this tunnel.
if ! port_open; then
  note "Opening SSH tunnel..."
  ERRF="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/fm_ssh_err.XXXXXX")"   # unique temp file each time to avoid stale/concurrent error mix-up
  /usr/bin/ssh -N -o ConnectTimeout=8 -o BatchMode=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -L "${PORT}:127.0.0.1:${RPORT}" "$HOST" 2>"$ERRF" &
  SSH_PID=$!
  OWNS=1
  # Clean up the tunnel we opened — and the drop-watchdog ($WATCH, set later) — no matter how we exit, so an
  # abnormal exit (signal/Force-Quit while the dialog is up) can't orphan the watchdog into a spurious
  # "Connection lost" notification. ${WATCH:-} tolerates the trap firing before WATCH is set (#10).
  trap 'kill "$SSH_PID" 2>/dev/null || true; kill "${WATCH:-}" 2>/dev/null || true' EXIT
  # Without -f, failure is detected by "port never becomes ready" (up to ~10 s); if ssh already exited, the port stays closed
  if ! wait_for port_open 40 0.25; then
    SSHERR="$(/bin/cat "$ERRF" 2>/dev/null | tr -d '"\\' | tr '\n' ' ' | cut -c1-300)"
    /bin/rm -f "$ERRF"
    err "Cannot reach server ($HOST).\n\nVerify that the following works in Terminal first:\n    ssh $HOST\n(First time: run that in Terminal and type yes to accept the host key -- this launcher can't prompt. Also confirm key-based (passwordless) login works.)\n\nError: $SSHERR"
  fi
  /bin/rm -f "$ERRF"
fi

# C12/C9: After opening the tunnel, treat the server's own X-FB-Server header as the authoritative identity
# (the SSH alias may differ from the server's self-reported name). Learn and persist it for future sessions
# so port reuse works correctly regardless of the alias name.
if [ "$OWNS" = "1" ]; then
  WHO2="$(server_id "$PORT")"
  if [ -n "$WHO2" ] && [ "$WHO2" != "$SRVID" ]; then
    SRVID="$WHO2"
    mkdir -p -m 700 "$(dirname "$IDFILE")" 2>/dev/null && printf '%s\n' "$SRVID" > "$IDFILE" 2>/dev/null || true   # -m 700: the learned-identity cache is per-user, not world-traversable (#9)
  fi
fi

# 2) Start the service remotely if it is not responding
if ! svc_ok; then
  note "Service is down, starting it..."
  /usr/bin/ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$SRV_START" >/dev/null 2>&1
  wait_for svc_ok 60 0.3   # ~18s, matches the Windows launcher; covers start.sh cold start (port pre-check + fb + proxy + watchdog) (M4)
fi

# 3) Open the browser
if ! svc_ok; then
  err "Tunnel is up but the file service on the server did not start.\nRun manually on the server:\n    $SRV_START"
fi
note "Connected, opening browser"
/usr/bin/open "$URL"

# 4) Session control: only manage the lifecycle of tunnels this script opened (OWNS=1).
#    Dialog open = connection alive; click "Disconnect" or close = script exits -> EXIT trap kills tunnel, releases port.
#    (When reusing an existing tunnel OWNS=0: no trap is set, we exit after opening the browser and never kill a tunnel we did not own.)
if [ "$OWNS" = "1" ]; then
  # Background watchdog: if the tunnel dies mid-session (timeout/sleep/network drop -> ssh exits), push a notification
  # so the user knows to reconnect, rather than leaving the dialog open with a false "connected" impression (C11)
  ( while kill -0 "$SSH_PID" 2>/dev/null; do sleep 3; done
    note "Connection lost (network drop or sleep). Close this dialog then double-click the Connector to reconnect." ) &
  WATCH=$!
  /usr/bin/osascript -e "display dialog \"Connected to ${HOST} (local port ${PORT})\n\nClick Disconnect when you are done.\nClosing the browser does not disconnect -- use this dialog to disconnect.\" with title \"$NAME\" buttons {\"Disconnect\"} default button 1" >/dev/null 2>&1
  DLG_RC=$?
  kill "$WATCH" 2>/dev/null || true
  # C10: dialog exits abnormally (no GUI/Aqua session etc., non-zero exit code) but tunnel is still alive ->
  #      do not immediately trigger EXIT trap and kill the good tunnel; instead wait for the tunnel process to finish naturally.
  if [ "$DLG_RC" -ne 0 ] && kill -0 "$SSH_PID" 2>/dev/null; then
    wait "$SSH_PID" 2>/dev/null || true
  fi
fi
