# Desktop Launcher (Server Connector)

Reduces "open terminal -> type `ssh -L ...` -> open browser -> type URL" to **double-clicking a desktop icon**.

```
Before:   open terminal -> ssh command -> keep window open -> open browser -> type URL -> log in
Launcher: double-click desktop icon -----------------------------------------> log in
```

Double-clicking the icon automatically: (1) opens an SSH tunnel -> (2) checks the server service and starts it if down -> (3) opens the browser to the login page -> (4) shows a small "Connector" window that manages the session — **close it when you are done to disconnect and release the port**.

> Note: neither the installer nor the launcher need a username or password — the server connection uses SSH key-based (passwordless) login. The filebrowser account credentials are entered on the login page that opens in the browser.

---

## Prerequisites (one time only)

Your machine must be able to `ssh` to the server **without a password**, with an alias configured (e.g. `myserver`). Verify: open Terminal / PowerShell and run

```
ssh myserver
```

If it connects immediately (first time: type `yes` to accept the host key) **without asking for a password**, you are ready. Then exit.

> If not yet configured: add your SSH public key to the server and create a `Host myserver` entry in `~/.ssh/config`.

---

## macOS

**Install (once):** double-click `client/macos/install.command`

- Most reliable method: open Terminal, type `bash ` and drag `install.command` into the window, then press Enter (runs `bash /path/to/install.command`) — avoids Gatekeeper issues from lost execute permissions on download.
- If double-clicking shows "unknown developer": right-click -> **Open** -> **Open** again; or go to **System Settings -> Privacy & Security** and click **Open Anyway**.
- The installer asks for the SSH alias (default `myserver`), the remote start command, and the local port (**a unique idle port is auto-selected per server** — accept the default), then creates **`<alias> Connector.app`** on your Desktop (e.g. `myserver Connector`).

**Use:** double-click **`<alias> Connector`** on the Desktop (e.g. `myserver Connector`) -> macOS notifications appear in the top-right corner at each stage (connecting -> tunnel -> opening browser). After a moment the browser opens automatically. A small **"Disconnect"** dialog will appear — while it is open, the connection is active. **Click "Disconnect" when you are done** to end the session and release the port (closing the browser tab does not disconnect — use this dialog; **if the network drops or the Mac sleeps, the tunnel auto-reconnects** — no need to relaunch).

---

## Windows 10 / 11

**Install (once):** double-click `client\windows\install.bat`

- Dialogs will ask for the SSH alias (default `myserver`), the remote start command, and the local port (**a unique idle port is auto-selected per server** — accept the default). A shortcut named **`<alias> Connector`** is created on your Desktop (e.g. `myserver Connector`).
- If SmartScreen blocks it: click **More info -> Run anyway**.

**Use:** double-click **`<alias> Connector`** on the Desktop -> a small **Connector window** opens (shows tunnel / port / browser progress) -> after connecting, the browser opens automatically. The window stays open showing "Connected — close to disconnect" (**auto-reconnects if the network drops or the PC sleeps**). **Close this window (or click "Disconnect") to end the session and release the port** (closing the browser does not disconnect). No black console window at any point.

---

## Upgrading an existing install (port collision fix + self-heal)

If an older Connector used port 8080 for every server, you may have connected to the wrong one. Upgrading only requires **re-running the installer**:

- Re-run `install.bat` (Windows) / `install.command` (macOS), **once per server** — each server is automatically assigned a distinct port (no longer crowding 8080); the existing shortcut is updated in place.
- Double protection after upgrade: (1) default ports are derived per alias so they differ from the start; (2) if ports still collide, the launcher **verifies identity** by reading the server's `X-FB-Server` header — reuses the tunnel if it is the right server, or **automatically switches to a free port** if not. You can never connect to the wrong server.
- Emergency fix without reinstalling: on Windows, edit line 2 of `%LOCALAPPDATA%\file-launcher\<alias>\config.txt` to a free port number; on macOS the port is baked into the `.app` so reinstalling is the only option.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Cannot reach server" dialog | Verify `ssh myserver` works without a password in Terminal / PowerShell; first time, type `yes` to accept the host key |
| Browser opens but page does not load | The server service is probably not running; the launcher auto-starts it — wait a few seconds and double-click again; if still failing, run `bash ~/filebrowser-ssh-kit/server/start.sh` on the server manually |
| Want to disconnect / port still in use | Close the Connector window (macOS: click "Disconnect" in the dialog) — that window is the on/off switch for the current session |
| Connection drops occasionally | Usually a network drop or computer sleep closed the SSH tunnel; the Connector **auto-reconnects** (title shows "Reconnecting..." then returns to "Connected"; macOS shows a "Reconnected" notification) — just wait, no action needed. If it never recovers, close the Connector window (macOS: close the dialog) and double-click again |
| Multiple servers / port clash | Run the installer once per server — each gets its own port and shortcut; if ports still clash, the launcher validates identity and self-heals by switching ports |
| Login credentials | Use the account you created during install |

---

## How it works

- **Zero dependencies:** macOS uses built-in `ssh` / `osascript` / `open`; Windows uses built-in OpenSSH + PowerShell. Nothing is installed.
- **Feedback and control:** on Windows a Connector window shows progress; on macOS notifications appear at each stage. After connecting, the window (macOS: the "Disconnect" dialog) acts as the session switch — close it to disconnect.
- **Tunnel:** `ssh -N -L <local-port>:127.0.0.1:8080 <alias>`, owned as a **child process** of the launcher. Closing the Connector (macOS: clicking "Disconnect") kills the tunnel and releases the port — nothing lingers in the background. (The remote port `8080` is the server's `PX_PORT` default; if you changed `PX_PORT` on the server, re-run the installer so the connector targets the new port.)
- **Auto-reconnect:** an established tunnel uses `ServerAliveInterval=15 x6` (~90s) so brief network jitter does not drop it; if it truly closes (sleep / extended outage) the launcher rebuilds it to the same port with backoff (2 -> 4 -> ... -> 30s cap), showing progress in the window / via notifications, until you disconnect — no manual relaunch.
- **Per-server ports:** each server gets a distinct local port (installer derives it from the alias, avoiding the crowded 8080 range). Multiple servers can be open simultaneously without interfering.
- **Wrong-server protection (identity check + self-heal):** every server response includes an `X-FB-Server` header. Before using a local port, if the port is occupied, the launcher checks whether "the other end is actually this server": reuses the tunnel if yes; **switches to a free port if no** (another server's tunnel or an unrelated program). You can never land on the wrong server even if ports collide.
- **Auto-start:** if the tunnel is up but the service is not responding, the launcher runs the remote start command over SSH.
- **Locally built shortcuts:** the installer generates the shortcut on your machine (not downloaded from the internet), so macOS Gatekeeper / Windows SmartScreen generally do not block it.
- Icons live in `client/icon/` (`make_icon.py` can regenerate them).
