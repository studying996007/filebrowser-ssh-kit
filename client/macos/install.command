#!/bin/bash
# Desktop Launcher - macOS Installer (double-click to run)
# Purpose: prompts for SSH alias + port -> generates "<Alias> Connector.app" on the Desktop (with icon, ready to double-click).
# No network access, no downloads. The .app is built locally, so Gatekeeper will not flag it as "unknown developer".
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
# Guard the icon dir explicitly: under `set -e`, a failing `cd $DIR/../icon` would abort the script
# with NO dialog and no message (the Terminal window just closes), leaving the user with no idea what
# went wrong. Surface a clear error instead — mirrors the Windows installer's icon check.
ICON_DIR="$DIR/../icon"
if [ ! -d "$ICON_DIR" ]; then
  /usr/bin/osascript -e "display dialog \"Icon folder not found next to this installer. Make sure you extracted the COMPLETE repository (not just the macos/ subfolder), then run this again.\" with title \"Install Server Connector\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1
  exit 1
fi
ICON_DIR="$(cd "$ICON_DIR" && pwd)"

ask(){ # $1 prompt  $2 default  -> output to stdout
  /usr/bin/osascript -e "text returned of (display dialog \"$1\" default answer \"$2\" with title \"Install Server Connector\" buttons {\"Continue\"} default button 1)"
}

HOST="$(ask "Server SSH alias (the name you type after ssh in your terminal):" "myserver" || true)"
[ -z "$HOST" ] && HOST="myserver"
# Only standard SSH Host characters are allowed. Any other character would break AppleScript/plist/sed,
# so reject and exit rather than silently producing a broken app.
# Whitelist approach: delete all legal characters; if anything remains, illegal characters are present.
if [ -n "$(printf '%s' "$HOST" | tr -d 'A-Za-z0-9._-')" ]; then
  /usr/bin/osascript -e "display dialog \"The alias contains special characters and cannot be used safely. Please use an alias containing only letters, digits, . _ - (e.g. myserver).\" with title \"Install Server Connector\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1
  exit 1
fi
# Shortcut name (needed before the port prompt; define early)
NAME="${HOST} Connector"

# Automatically pick a local port not already used by another Connector app:
# scan the baked-in PORT= lines of every launcher on the Desktop.
# Different servers must use different local ports; otherwise whichever one grabs the port first
# is what every subsequent double-click connects to.
used_ports=" "
for L in "$HOME"/Desktop/*.app/Contents/MacOS/launcher; do
  [ -f "$L" ] || continue
  case "$L" in *"/${NAME}.app/"*) continue;; esac   # skip self: re-installing same host reuses its port
  p="$(/usr/bin/sed -n 's/^PORT="\([0-9][0-9]*\)".*/\1/p' "$L" | head -1)"
  [ -n "$p" ] && used_ports="${used_ports}${p} "
done
# Default port is derived from the alias to stay out of the crowded 8080 range (8300-9299)
BASE=$(( 8300 + $(printf '%s' "$HOST" | cksum | awk '{print $1}') % 1000 ))
SUGGEST=$BASE
while case "$used_ports" in *" $SUGGEST "*) true;; *) false;; esac; do SUGGEST=$((SUGGEST+1)); done

PORT="$(ask "Local port (must be unique per server; an idle port has been pre-selected -- just accept it):" "$SUGGEST" || true)"
case "$PORT" in ""|*[!0-9]*) PORT="$SUGGEST";; esac   # empty or non-numeric -> fall back to auto-selected port
case "$used_ports" in
  *" $PORT "*) /usr/bin/osascript -e "display dialog \"Port $PORT is already used by another server. Consider using the auto-selected port $SUGGEST instead. You can keep $PORT but do not use both servers at the same time.\" with title \"Port Warning\" buttons {\"OK\"} default button 1 with icon caution" >/dev/null 2>&1;;
esac

# Shortcut name already set above; place the .app on the Desktop
APP="$HOME/Desktop/${NAME}.app"

SRV_START="$(ask "Remote command to start the service:" "~/filebrowser-ssh-kit/server/start.sh" || true)"
[ -z "$SRV_START" ] && SRV_START="~/filebrowser-ssh-kit/server/start.sh"
# SRV_START is baked into the launcher (the sed substitution below + the osascript dialog inside the
# launcher). Restrict it to safe path/command characters so a stray | & \ " cannot corrupt the sed
# replacement or the AppleScript string. Mirrors the HOST whitelist above. (M5)
if [ -n "$(printf '%s' "$SRV_START" | tr -d 'A-Za-z0-9 ._/~-')" ]; then
  /usr/bin/osascript -e "display dialog \"The remote command contains unsupported characters. Use a plain path such as ~/filebrowser-ssh-kit/server/start.sh (letters, digits, space, and . _ / ~ - only).\" with title \"Install Server Connector\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1
  exit 1
fi

# Rebuild the .app skeleton
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>org.filebrowser-ssh-kit.launcher</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Icon: prefer converting from PNG with the system iconutil (most reliable); fall back to the bundled icon.icns
ICNS_OUT="$APP/Contents/Resources/icon.icns"
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  SET="$(mktemp -d)/icon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    /usr/bin/sips -z $s $s        "$ICON_DIR/icon.png" --out "$SET/icon_${s}x${s}.png"     >/dev/null 2>&1 || true
    d=$((s*2)); /usr/bin/sips -z $d $d "$ICON_DIR/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
  done
  /usr/bin/iconutil -c icns "$SET" -o "$ICNS_OUT" 2>/dev/null || cp "$ICON_DIR/icon.icns" "$ICNS_OUT"
else
  cp "$ICON_DIR/icon.icns" "$ICNS_OUT"
fi

# Generate launcher (fill host/port/srv-start into the template)
sed -e "s|__HOST__|$HOST|g" -e "s|__PORT__|$PORT|g" -e "s|__SRVID__|$HOST|g" \
    -e "s|__SRV_START__|$SRV_START|g" \
    "$DIR/launcher.template.sh" > "$APP/Contents/MacOS/launcher"
chmod +x "$APP/Contents/MacOS/launcher"

# Tell Finder to refresh the icon immediately
touch "$APP"

/usr/bin/osascript -e "display dialog \"OK: '${NAME}' has been created on your Desktop.\n\nDouble-click it anytime to connect -- no terminal or manual commands needed.\" with title \"Installation Complete\" buttons {\"OK\"} default button 1" >/dev/null 2>&1
echo "Done: $APP  (HOST=$HOST PORT=$PORT)"
