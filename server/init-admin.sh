#!/usr/bin/env bash
# Set (or reset) the filebrowser "admin" password explicitly, instead of relying on
# filebrowser's first-run default. Also tightens the database file permissions.
#
# Why this exists: on first launch filebrowser auto-creates an admin account whose
# password is either a build-specific default or randomly printed to the log — easy
# to miss, and easy to leave weak. This script lets you choose the password up front.
#
# Usage:
#   bash server/init-admin.sh                          # prompts (hidden input)
#   FB_ADMIN_PASSWORD='...' bash server/init-admin.sh  # non-interactive
#
# Password length: FB_MIN_PW_LEN (default 12, matching filebrowser's own built-in minimum). This value
# is also written into filebrowser's own config, so the binary and this script never disagree about
# what counts as long enough.
#
# Security note: filebrowser's CLI takes the password as a command-line argument, so
# it is briefly visible in the host's process list (ps) during this one-shot call.
# The database is chmod 600'd immediately afterwards.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/config.sh"   # provides BIN (filebrowser binary) and DB (database path)

umask 0077   # any db/config this script creates is owner-only (600) from birth (L2)

MIN_PW_LEN="${FB_MIN_PW_LEN:-12}"
# Validate before anything else (even the binary check): a non-integer .env value would otherwise crash
# the bare '[' length comparison below with a cryptic "integer expression expected" mid-setup (#7).
case "$MIN_PW_LEN" in
  ''|*[!0-9]*) echo "✗ FB_MIN_PW_LEN must be a positive integer (got: '${FB_MIN_PW_LEN:-}')." >&2; exit 1;;
esac

if [ ! -x "$BIN" ]; then
  echo "✗ filebrowser binary not found at: $BIN" >&2
  echo "  Install it first (run ./install.sh), or set FB_BIN in .env." >&2
  exit 1
fi

# ---- Obtain the password ----
pw="${FB_ADMIN_PASSWORD:-}"
if [ -z "$pw" ]; then
  printf 'Set a password for the filebrowser "admin" account (min %s chars): ' "$MIN_PW_LEN"
  read -rs pw; echo
  printf 'Repeat: '
  read -rs pw2; echo
  if [ "$pw" != "$pw2" ]; then echo "✗ passwords do not match." >&2; exit 1; fi
fi
if [ "${#pw}" -lt "$MIN_PW_LEN" ]; then
  echo "✗ password too short (minimum $MIN_PW_LEN characters)." >&2
  exit 1
fi

# ---- Initialise / align filebrowser config ----
# 'config init' is NOT idempotent (it errors on an existing db), so only run it when the
# db is absent; pin the password-length policy so the binary accepts what this script did.
if [ ! -f "$DB" ]; then
  if ! "$BIN" -d "$DB" config init --minimumPasswordLength "$MIN_PW_LEN" >/dev/null 2>&1; then
    echo "✗ 'filebrowser config init' failed." >&2; exit 1
  fi
else
  # Existing db: align its policy with MIN_PW_LEN. Tolerate forks lacking this flag.
  "$BIN" -d "$DB" config set --minimumPasswordLength "$MIN_PW_LEN" >/dev/null 2>&1 || true
fi

# ---- Create the admin user, or reset its password if it already exists ----
# Detect existence by OUTCOME, not by parsing 'users ls' columns — a future filebrowser could reorder
# the columns or add a stdout banner and silently break a positional parse. Instead: try to add admin;
# if that fails because the user already exists, the update resets the password. If BOTH fail, the
# password itself was rejected (too short, or — filebrowser also blocks well-known weak passwords —
# too common). We surface filebrowser's own 'error' lines so the user knows to pick a less common one.
show_fb_err(){ printf '%s\n' "$1" | grep -i 'error' | sed 's/^/  filebrowser: /' >&2; }

if out_add="$("$BIN" -d "$DB" users add admin "$pw" --perm.admin --scope . 2>&1)"; then
  echo "✓ admin account created."
elif out_upd="$("$BIN" -d "$DB" users update admin -p "$pw" 2>&1)"; then
  echo "✓ admin password updated."
else
  # Neither add nor update succeeded -> this is not an "already exists" case; the password was rejected.
  echo "✗ could not set the admin password (try a longer, less common one)." >&2
  show_fb_err "$out_add"; show_fb_err "$out_upd"
  exit 1
fi

# ---- Secure the database file ----
# filebrowser creates it group-readable (640); it holds bcrypt hashes and the JWT signing key.
chmod 600 "$DB" 2>/dev/null || true
echo "✓ database secured (chmod 600): $DB"
