# filebrowser-ssh-kit

Browse and manage files on a remote Linux server from your own browser — over an
SSH tunnel, with nothing exposed to the public internet.

## What it does

- **Manage files from your browser** — browse, rename, move, delete, upload,
  download, and preview files, images, and text on the remote server (powered by
  [filebrowser](https://filebrowser.org)).
- **Reachable over SSH only** — filebrowser binds to `127.0.0.1`; you connect
  through an `ssh -L` tunnel, so encryption and the first authentication layer
  come from SSH. No public port to expose, no TLS to set up.
- **One-click desktop connector** (macOS & Windows) — double-click an icon to open
  the tunnel, start the remote service if it isn't running, and open the browser;
  close it to disconnect and release the port. No terminal commands to type.
- **"Copy path" button** — copies the **absolute server-side path** of the file or
  folder you're viewing, ready to paste into a terminal or script.
- **Runs unattended** — a watchdog restarts filebrowser or the proxy if either
  exits, and thumbnails/downloads stay cache-correct (no stale files after a change).
- **One-command install** — `./install.sh` checks prerequisites, installs the one
  Python dependency, optionally fetches the filebrowser binary, and writes `.env`.

## Requirements

- **Server:** Linux/macOS, `bash`, `python3` ≥ 3.8 with `aiohttp` (installer sets
  this up), `ssh`, `curl`, and the `filebrowser` binary (installer can fetch it).
- **Client:** built-in `ssh` (macOS/Windows 10+ both ship OpenSSH); nothing to
  install. Key-based (passwordless) SSH to the server with a `~/.ssh/config` Host
  alias.

## How to use it

**On the server — one-time setup:**
```
git clone https://github.com/studying996007/filebrowser-ssh-kit
cd filebrowser-ssh-kit
./install.sh                 # installs deps, optional binary, writes .env, sets the admin password
nano .env                    # set FB_ROOT (the folder to serve); everything else has sane defaults
bash server/start.sh         # starts filebrowser + proxy + watchdog (run again after a reboot)
```

**On your laptop — each time you want to connect:**

- **Easiest — desktop connector:** run `client/macos/install.command` or
  `client/windows/install.bat` *once* to create a Desktop icon. After that, just
  double-click the icon: it opens the SSH tunnel, starts the remote service if it's
  down, and opens the browser. Close it to disconnect and free the port.
- **Or by hand:** `ssh -L 8080:127.0.0.1:8080 <your-ssh-alias>`, then open
  `http://localhost:8080` in your browser.

Log in with the admin account from setup and browse your files. The **📋 Copy path**
button at the bottom-right copies the server path of whatever you're viewing.

## The "Copy path" button

Logged into filebrowser, a **📋 Copy path** button sits at the bottom-right. It
copies the **server path** of the file/folder you're viewing — handy for pasting
into a terminal. The prefix is configured, never hardcoded:

- `FB_PATH_ROOT` — absolute prefix to show (empty → shows the in-app path).
- `FB_PATH_MAP` — optional JSON `{"alice":"/data/alice"}` for per-account prefixes.

## Security model

- filebrowser (`FB_PORT`) and the proxy (`PX_PORT`) both bind **`127.0.0.1` only**.
  The **only** remote entry point is an **SSH tunnel** — that's where transport
  encryption and the first layer of authentication come from. No plaintext port is
  ever exposed on the network.
- **Do not** bind these to `0.0.0.0` or expose them publicly without putting TLS
  and authentication in front. This kit is designed for the tunnel model.
- No credentials live in this repo. filebrowser stores passwords as **bcrypt**
  hashes (never plaintext) and verifies them server-side; the password travels
  only inside the SSH tunnel, and the proxy never logs request bodies.
- **Set the admin password up front** instead of relying on filebrowser's first-run
  default. The installer offers to; you can also run it anytime:
  ```
  bash server/init-admin.sh     # hidden prompt — or FB_ADMIN_PASSWORD=... for non-interactive
  ```
  Minimum length is `FB_MIN_PW_LEN` (default 12, matching filebrowser's own minimum); filebrowser additionally rejects
  well-known weak passwords.
- The database (`FB_DB`) holds the bcrypt hashes and the JWT signing key. filebrowser
  creates it group-readable, so `start.sh` and `init-admin.sh` tighten it to `600` —
  keep it that way on shared hosts.

## Configuration reference

All settings live in `.env` (copied from `.env.example`, gitignored). See that
file for `FB_SERVER_ID`, `FB_ROOT`, `FB_PORT`, `PX_PORT`, `FB_BIN`, `FB_DB`,
`FB_PATH_ROOT`, `FB_PATH_MAP`, and `FB_MIN_PW_LEN`. Advanced operational knobs
(watchdog backoff `KA_BASE`/`KA_CAP`, `FB_LOCK_WAIT`, and log paths) are listed as
commented lines in `.env.example`. If you change `PX_PORT`, regenerate the desktop
connectors so their tunnel target matches.

## Managing the service

| Action | Command |
|---|---|
| Start / restart | `bash server/start.sh` |
| Stop | `bash server/stop.sh` |
| Set / reset admin password | `bash server/init-admin.sh` |
| Logs | `~/filebrowser.log`, `~/filebrowser-proxy.log`, `~/filebrowser-keepalive.log` |

`start.sh` launches three processes (filebrowser on the internal port, the inject
proxy on the tunnel port, and the watchdog) and verifies each came up before
reporting success. It does **not** auto-start on reboot — run it again after a
server restart.

## How it works

Your browser → SSH tunnel → proxy (`127.0.0.1:PX_PORT`) → filebrowser
(`127.0.0.1:FB_PORT`). The proxy injects the button into HTML responses only and
streams everything else verbatim, so downloads and uploads are unaffected.

## License

MIT — see [LICENSE](LICENSE).
