#!/usr/bin/env bash
# filebrowser-ssh-kit installer.
#   ./install.sh           full install (prereqs -> python deps -> optional binary -> configure)
#   ./install.sh --check    only verify prerequisites, then exit
# pipefail so a failed download in 'curl ... | bash' is not masked by bash's exit 0 -> false success (#9).
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ONLY=0; [ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "[1/6] Platform"
ok "$(uname -s) / $(uname -m)"

echo "[2/6] Prerequisites"
miss=0
for t in bash ssh curl; do
  if have "$t"; then ok "$t"; else bad "$t not found"; miss=1; fi
done
if have python3; then
  ok "python3 ($(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?'))"
else
  bad "python3 not found"; miss=1
fi
if [ "$miss" -ne 0 ]; then bad "Missing prerequisites — install them and re-run."; exit 1; fi
if [ "$CHECK_ONLY" -eq 1 ]; then ok "All prerequisites present."; exit 0; fi

echo "[3/6] Python dependencies"
if python3 -c 'import aiohttp' 2>/dev/null; then
  ok "aiohttp already available"
else
  warn "aiohttp missing — creating venv at $KIT/.venv"
  if python3 -m venv "$KIT/.venv" && "$KIT/.venv/bin/pip" install -q -r "$KIT/requirements.txt"; then
    ok "installed aiohttp into .venv"
  else
    rm -rf "$KIT/.venv"   # don't leave a half-built venv (created, but pip failed) to confuse the next run (#12)
    bad "failed to install aiohttp (try: pip install -r requirements.txt)"; exit 1
  fi
fi

echo "[4/6] filebrowser binary"
BIN="${FB_BIN:-${HOME:-}/.local/bin/filebrowser}"
if [ -x "$BIN" ]; then
  ok "found $BIN"
else
  warn "filebrowser not found at $BIN"
  # [ -t 0 ]: only prompt on a real terminal. Under 'curl ... | bash' stdin IS the script text, so an
  # unguarded 'read' would consume a script line as the answer and silently make the wrong choice (#11).
  if [ -t 0 ]; then
    printf '  Download the official binary now? [y/N] '; read -r ans
  else
    warn "non-interactive stdin (curl | bash?) — skipping the binary download; install it later via the link below."; ans=N
  fi
  case "$ans" in
    y|Y)
      mkdir -p "$(dirname "$BIN")"
      # Official installer: detects OS/arch and fetches a verified release binary.
      # Runs filebrowser's official installer over HTTPS (opt-in above). No independent checksum — review get.sh first if you prefer.
      if curl -fsSL https://raw.githubusercontent.com/filebrowser/filebrowser/master/get.sh | bash; then
        ok "filebrowser installed"
      else
        bad "download failed — install manually: https://filebrowser.org/installation"
      fi ;;
    *) warn "skipped — install manually: https://filebrowser.org/installation" ;;
  esac
fi

echo "[5/6] Configuration"
if [ -f "$KIT/.env" ]; then
  ok ".env already exists — leaving it untouched"
else
  cp "$KIT/.env.example" "$KIT/.env"
  chmod 600 "$KIT/.env"   # .env may hold FB_ADMIN_PASSWORD / path config — keep it owner-only on shared hosts (#8)
  ok "created .env from .env.example (mode 600)"
fi

echo "[6/6] filebrowser admin account"
if [ ! -x "$BIN" ]; then
  warn "filebrowser not installed yet — after installing it, set the admin password with:"
  warn "  bash $KIT/server/init-admin.sh"
else
  if [ -t 0 ]; then
    printf '  Set the admin password now (recommended)? [Y/n] '; read -r ans
  else
    warn "non-interactive stdin — skipping admin setup; run later: bash $KIT/server/init-admin.sh"; ans=n
  fi
  case "$ans" in
    n|N) warn "skipped — before first start, run: bash $KIT/server/init-admin.sh" ;;
    *) FB_ENV="$KIT/.env" bash "$KIT/server/init-admin.sh" \
         || warn "admin setup did not finish — you can rerun: bash $KIT/server/init-admin.sh" ;;
  esac
fi
echo
echo "Done. Next steps:"
echo "  1) edit $KIT/.env   (set FB_SERVER_ID, FB_ROOT, optionally FB_PATH_ROOT)"
echo "  2) bash $KIT/server/start.sh"
echo "  3) from your laptop: ssh -L 8080:127.0.0.1:8080 <your-ssh-alias>  ->  http://localhost:8080"
