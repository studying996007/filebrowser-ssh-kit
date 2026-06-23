#!/usr/bin/env bash
# Watchdog for filebrowser and the injection proxy: polls both processes periodically and
# restarts whichever has died. Launched in the background by start.sh — you do not run this directly.
# On repeated crashes: per-service exponential back-off (15 s -> 120 s max) to avoid log storms.
# Logs are trimmed when they exceed LOG_MAX bytes to prevent filling up $HOME.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/config.sh"

# Single-instance lock: at most one watchdog may run at any time (it in turn ensures at most one
# filebrowser and one proxy). If the lock is unavailable this instance exits immediately.
# We use flock -w (wait up to FB_LOCK_WAIT seconds) rather than -n (fail immediately):
# start.sh just PKILLed the old watchdog; it or an orphan process from a prior session may hold the
# lock for a brief moment while exiting. Waiting avoids the race "transient lock contention ->
# watchdog silently exits -> services run unmonitored and never auto-restart" (a real bug we hit).
# If a genuinely long-lived watchdog is running the wait simply times out and this instance exits.
exec 9>"$LOCK" || exit 1
flock -w "$FB_LOCK_WAIT" 9 || { echo "$(date '+%F %T') Could not acquire watchdog lock after ${FB_LOCK_WAIT}s (another watchdog already running?). Exiting." >&2; exit 0; }
# Lock acquired — about to enter the poll loop. Write the ready marker so start.sh can confirm
# the watchdog actually started (rather than silently exiting before start.sh noticed).
: > "$KA_READY" 2>/dev/null || true

fb_fails=0; px_fails=0
fb_next=0;  px_next=0          # epoch seconds: next scheduled check time for each service (0 = immediately)
while true; do
  trim_log "$FB_LOG" "$PX_LOG"
  now=$(date +%s)

  # Each service has its own independent back-off schedule so a crash-looping service does not
  # inflate the retry delay for the healthy one. Previously a shared max(fb_fails, px_fails) counter
  # caused a persistently broken service to delay the other's recovery to the full 120 s cap.
  if [ "$now" -ge "$fb_next" ]; then
    if PGREP -f "$FB_MATCH" >/dev/null 2>&1; then fb_fails=0; else launch_fb; fb_fails=$((fb_fails + 1)); fi
    fb_next=$((now + $(backoff_secs "$fb_fails")))
  fi
  if [ "$now" -ge "$px_next" ]; then
    if PGREP -f "$PX_MATCH" >/dev/null 2>&1; then px_fails=0; else launch_px; px_fails=$((px_fails + 1)); fi
    px_next=$((now + $(backoff_secs "$px_fails")))
  fi

  # 9>&- : run the sleep WITHOUT inheriting fd 9 (the single-instance flock). The watchdog spends almost
  # all its time here; pkill targets the bash PID, not this child. Without closing fd 9 the orphaned sleep
  # would keep the OFD — and thus the flock — alive for up to KA_CAP seconds after the watchdog is killed,
  # stalling/failing the next start.sh's watchdog acquisition (mirrors the launch_fb/launch_px 9>&-).
  sleep "$(ka_next_wake "$(date +%s)" "$fb_next" "$px_next")" 9>&-
done
