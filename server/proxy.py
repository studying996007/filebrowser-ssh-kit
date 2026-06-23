#!/usr/bin/env python3
"""filebrowser "Copy path" inject reverse-proxy.

Listens on 127.0.0.1:8080 -> forwards to filebrowser on 127.0.0.1:8090.
Injects a small floating "Copy path" button into filebrowser's own HTML
pages; all other traffic (API / static / up/download / WebSocket) streams
through untouched. The button copies the server path of the current
file/folder; the path prefix is configured via FB_PATH_ROOT / FB_PATH_MAP
(see .env.example) — nothing about the deployment is hardcoded.

Requires: python3 + aiohttp.
"""
import asyncio
import gzip
import json
import os
import sys

import aiohttp
from aiohttp import web, WSMsgType
from multidict import CIMultiDict
from yarl import URL

# Ports can be overridden by env vars (defaults 8080 -> 8090): keeps config.sh in sync and allows test instances
UPSTREAM_PORT = int(os.environ.get("FB_UPSTREAM_PORT", "8090"))
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("FB_PROXY_PORT", "8080"))
UPSTREAM = "http://127.0.0.1:%d" % UPSTREAM_PORT
UPSTREAM_HOST = "127.0.0.1:%d" % UPSTREAM_PORT

# Identity tag written into every response as X-FB-Server. The client launcher reads this
# before reusing a local port to confirm it is talking to the right server; a mismatch
# (another tunnel occupying the same port) triggers an automatic port switch. Set by FB_SERVER_ID.
# Strip CR/LF: aiohttp rejects header values containing them, and a CRLF-line-ending .env (edited on
# Windows) would otherwise leave a trailing '\r' here that makes aiohttp 500 every response — surfacing
# as a misleading "proxy down / aiohttp missing?" at start.sh (#1). config.sh de-CRLFs .env at source
# too; this also covers FB_SERVER_ID exported directly into the environment.
SERVER_ID = os.environ.get("FB_SERVER_ID", "").replace("\r", "").replace("\n", "")

# Path-display config for the "Copy path" button. All optional.
#   FB_PATH_ROOT : absolute server-path prefix to show (empty = show in-app path only)
#   FB_PATH_MAP  : JSON {username: prefix} for per-account prefixes (empty = all use FB_PATH_ROOT)
PATH_ROOT = os.environ.get("FB_PATH_ROOT", "").rstrip("/")
try:
    PATH_MAP = json.loads(os.environ.get("FB_PATH_MAP") or "{}")
    if not isinstance(PATH_MAP, dict):
        PATH_MAP = {}
except Exception:
    PATH_MAP = {}

# The injected button reads two filebrowser-2.x front-end conventions: the JWT in localStorage['jwt']
# (to pick the per-user path prefix) and the '/files/...' SPA route (to derive the relative path). Both
# are read defensively and FAIL SOFT — if a future filebrowser changes either, prefix()/rel() fall back
# (the button copies the configured root or an empty path) rather than breaking the page.
INJECT_TEMPLATE = r"""
<script>
(function () {
  if (window.__ccPathBtn) return; window.__ccPathBtn = 1;
  // Path-display config injected by the proxy (deployer-controlled, JSON).
  var CFG = __CC_CFG__;
  var ROOT = CFG.root || '';
  var MAP  = CFG.map  || {};
  function prefix() {
    try {
      var t = localStorage.getItem('jwt'); if (!t) return ROOT;
      var p = t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      while (p.length % 4) p += '=';
      var u = (JSON.parse(decodeURIComponent(escape(atob(p)))).user) || {};
      return MAP[u.username] || ROOT;
    } catch (e) { return ROOT; }
  }
  function rel() {
    var s = location.pathname + location.hash;
    var m = s.match(/\/files(\/[^?#]*)?/);
    return (m && m[1]) ? decodeURIComponent(m[1]) : '';
  }
  function abspath() {
    var a = (prefix() + rel()).replace(/\/+$/, '');
    return a || prefix() || rel() || '/';
  }
  function toast(msg) {
    var d = document.createElement('div');
    d.textContent = msg;
    d.style.cssText = 'position:fixed;left:50%;bottom:78px;transform:translateX(-50%);' +
      'max-width:84vw;background:#222;color:#fff;padding:10px 16px;border-radius:8px;' +
      'font:13px/1.5 -apple-system,Segoe UI,sans-serif;white-space:pre-wrap;word-break:break-all;' +
      'z-index:2147483647;box-shadow:0 4px 18px rgba(0,0,0,.35)';
    document.body.appendChild(d);
    setTimeout(function () { try { d.remove(); } catch (e) {} }, 2800);
  }
  function copy() {
    var abs = abspath();
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(abs).then(
        function () { toast('Copied:\n' + abs); },
        function () { window.prompt('Copy path manually:', abs); }
      );
    } else { window.prompt('Copy path manually:', abs); }
  }
  function ensure() {
    if (!document.body || document.getElementById('cc-path-btn')) return;
    var b = document.createElement('button');
    b.id = 'cc-path-btn'; b.type = 'button';
    b.title = 'Copy the server path of the current file/folder';
    b.textContent = '📋 Copy path';
    b.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;' +
      'background:#2d6cdf;color:#fff;border:0;border-radius:22px;padding:10px 16px;' +
      'font:14px/1 -apple-system,Segoe UI,sans-serif;cursor:pointer;box-shadow:0 3px 12px rgba(0,0,0,.3)';
    b.addEventListener('mouseenter', function () { b.style.background = '#2257c0'; });
    b.addEventListener('mouseleave', function () { b.style.background = '#2d6cdf'; });
    b.addEventListener('click', copy);
    document.body.appendChild(b);
  }
  function boot() { ensure(); setInterval(ensure, 1500); }
  if (document.body) boot();
  else document.addEventListener('DOMContentLoaded', boot);
})();
</script>
"""
# json.dumps does not escape '<', so a deployer-set FB_PATH_ROOT / FB_PATH_MAP value containing
# '</script>' (or the '<!--<script>' parser-confusion sequence) could break out of / derail this inline
# <script>. Escaping every '<' to its JSON unicode-escape form is valid JSON, renders back to '<' in JS,
# and guarantees no '<' ever reaches the HTML tokenizer — strictly safer than only escaping '</'.
INJECT = INJECT_TEMPLATE.replace(
    "__CC_CFG__", json.dumps({"root": PATH_ROOT, "map": PATH_MAP}).replace("<", "\\u003c"))

# Hop-by-hop headers that must not be forwarded. 'expect' is included so a client's
# Expect: 100-continue is handled at this proxy's own HTTP layer and not double-handled upstream.
HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length", "expect",
}


def fwd_headers(headers):
    """Copy headers, stripping hop-by-hop ones; CIMultiDict preserves duplicate headers (e.g. multiple Set-Cookie)."""
    out = CIMultiDict()
    for k, v in headers.items():
        if k.lower() not in HOP:
            out.add(k, v)
    return out


def fixup_location(headers):
    """If the upstream redirects using an absolute internal URL, rewrite it to a relative path so the browser doesn't follow the wrong host."""
    loc = headers.get("Location")
    if loc and UPSTREAM_HOST in loc:
        headers["Location"] = loc.replace(UPSTREAM, "").replace(UPSTREAM_HOST, "")


async def handle(request):
    # WebSocket upgrade -> hand off to WS tunnel
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await ws_proxy(request)

    target = URL(UPSTREAM + request.raw_path, encoded=True)  # raw_path includes query string
    req_headers = fwd_headers(request.headers)
    req_headers["Host"] = UPSTREAM_HOST
    # Transparent compression: only negotiate what the client actually wants (gzip only, so we can
    # decompress for HTML injection); if the client didn't ask for compression, request identity.
    # Without this override aiohttp would add Accept-Encoding: gzip on its own.
    ae = request.headers.get("Accept-Encoding", "").lower()
    req_headers["Accept-Encoding"] = "gzip" if "gzip" in ae else "identity"

    session = request.app["session"]
    body = request.content if request.body_exists else None
    try:
        up = await session.request(
            request.method, target, headers=req_headers, data=body,
            allow_redirects=False,
        )
    except Exception as e:  # upstream unreachable (filebrowser not started / stuck)
        # Include identity header even on 502: the launcher's second probe reads X-FB-Server to
        # confirm it is talking to the right server; missing header would look like "wrong process"
        # and trigger a needless port switch (C1).
        h = {"X-FB-Server": SERVER_ID} if SERVER_ID else {}
        # Log the detail server-side (stderr -> proxy log), but never reflect the exception repr back to
        # the client: it discloses the internal upstream host/port and some OSError reprs leak paths (M1).
        print("proxy upstream error: %r" % (e,), file=sys.stderr, flush=True)
        return web.Response(status=502, text="502 Bad Gateway: upstream filebrowser is not responding.", headers=h)

    ctype = up.headers.get("Content-Type", "")

    # ---- Inject only into filebrowser's own authenticated shell pages ----
    # Conditions: (1) response is HTML, (2) not a HEAD request, (3) path is outside /api/ and /share/.
    # Excluding /api/: /api/raw (raw download) and /api/preview (thumbnails) carry the real MIME of
    # user files — a user's .html file is text/html too; injecting by Content-Type alone would
    # corrupt the download and buffer the whole file in memory. Excluding /share/: public share
    # pages are viewed by anonymous visitors, and the Copy-path button would expose the server-path
    # prefix (FB_PATH_ROOT) to them. filebrowser's own shell pages live on the remaining non-/api/
    # routes (/, /files/..., /login).
    inject = (ctype.lower().startswith("text/html")
              and up.status == 200            # only a normal full document — never a 206 Partial (would desync Content-Range from the body) or an error/redirect HTML body (#3)
              and request.method != "HEAD"
              and not request.path.startswith(("/api/", "/share")))
    if inject:
        try:
            raw = await up.read()
        except aiohttp.ClientError as e:  # upstream truncated the body mid-response (filebrowser killed / NFS stall): return 502 WITH X-FB-Server, not an unhandled 500 (#4)
            print("proxy upstream read error: %r" % (e,), file=sys.stderr, flush=True)
            h = {"X-FB-Server": SERVER_ID} if SERVER_ID else {}
            return web.Response(status=502, text="502 Bad Gateway: upstream filebrowser response was truncated.", headers=h)
        enc = up.headers.get("Content-Encoding", "").lower()
        oh = fwd_headers(up.headers)
        try:
            data = gzip.decompress(raw) if enc == "gzip" else raw
            text = data.decode("utf-8")
            if "</body>" in text:
                text = text.replace("</body>", INJECT + "</body>", 1)
            elif text:                       # only append to a NON-empty doc; never turn an empty body into the injected script (#3)
                text = text + INJECT
            out = text.encode("utf-8")
            oh.pop("Content-Encoding", None)  # decompressed + injected -> send as identity
        except Exception:
            out = raw  # decompression/decode failed: pass upstream bytes through unchanged, keeping Content-Encoding
        for h in ("Content-Length", "ETag", "Last-Modified",
                  "Content-Security-Policy", "Content-Security-Policy-Report-Only"):
            oh.pop(h, None)
        oh["Cache-Control"] = "no-store"  # modified page must not be cached
        if SERVER_ID:
            oh["X-FB-Server"] = SERVER_ID
        fixup_location(oh)
        return web.Response(status=up.status, headers=oh, body=out)

    # ---- Everything else: stream through, content untouched ----
    oh = fwd_headers(up.headers)
    if SERVER_ID:
        oh["X-FB-Server"] = SERVER_ID
    # Cache policy for streamed (non-injected) responses. filebrowser emits `Cache-Control: private`
    # + Last-Modified on /api/raw and /api/preview (thumbnails, incl. keyed ones), which triggers
    # heuristic browser caching → stale content after a file changes without a mtime bump (cp -p,
    # tar extract, rsync without --checksum, git checkout, restore from backup). Some builds also
    # leave /api/resources (directory listings) cacheable. So for ANY /api/ response: if the
    # upstream did not already forbid caching, force `no-cache` (may be stored but must revalidate
    # via ETag/Last-Modified → latest file, or a cheap 304). We never downgrade a stricter upstream
    # policy — an existing no-store / no-cache (e.g. filebrowser's own /api/resources) is left as-is.
    p = request.path
    if p.startswith("/api/"):
        up_cc = oh.get("Cache-Control", "").lower()
        if "no-store" not in up_cc and "no-cache" not in up_cc:
            oh["Cache-Control"] = "no-cache"
    fixup_location(oh)
    resp = web.StreamResponse(status=up.status, headers=oh)
    cl = up.headers.get("Content-Length")
    if cl is not None:
        try:
            resp.content_length = int(cl)
        except ValueError:
            pass
    await resp.prepare(request)
    try:
        async for chunk in up.content.iter_chunked(64 * 1024):
            await resp.write(chunk)
        await resp.write_eof()
    except (ConnectionResetError, ConnectionError, asyncio.TimeoutError, aiohttp.ClientError):
        pass  # client disconnect / upstream read timeout / upstream truncation (ClientPayloadError, #4): exit silently, release() in finally recycles the connection
    finally:
        up.release()
    return resp


async def ws_proxy(request):
    # heartbeat: also PING the *client* every 30 s. Without it a silent half-open client (laptop sleep,
    # tunnel dropped with no RST) parks c2u() in client_ws.receive() forever, leaking the coroutine pair
    # and the upstream WS until the process restarts — the upstream-side heartbeat alone can't detect this (#2).
    client_ws = web.WebSocketResponse(heartbeat=30)
    await client_ws.prepare(request)
    request.app["websockets"].add(client_ws)  # track for graceful shutdown (L4)
    session = request.app["session"]
    target = URL("ws://" + UPSTREAM_HOST + request.raw_path, encoded=True)
    h = {k: request.headers[k] for k in
         ("Cookie", "X-Auth", "Authorization", "Sec-WebSocket-Protocol")
         if k in request.headers}
    try:
        # heartbeat: PING the upstream every 30 s. The session's sock_read timeout governs HTTP body
        # reads only, NOT WebSocket frame reads — so without a heartbeat a wedged/half-open upstream WS
        # (e.g. a SIGSTOP'd filebrowser) would pin the u2c() coroutine and leak the connection forever.
        up_ws = await session.ws_connect(target, headers=h, heartbeat=30)
    except Exception:
        request.app["websockets"].discard(client_ws)  # untrack (L4)
        await client_ws.close()
        return client_ws

    async def c2u():
        async for msg in client_ws:
            if msg.type == WSMsgType.TEXT:
                await up_ws.send_str(msg.data)
            elif msg.type == WSMsgType.BINARY:
                await up_ws.send_bytes(msg.data)
            else:
                break
        await up_ws.close()

    async def u2c():
        async for msg in up_ws:
            if msg.type == WSMsgType.TEXT:
                await client_ws.send_str(msg.data)
            elif msg.type == WSMsgType.BINARY:
                await client_ws.send_bytes(msg.data)
            else:
                break
        await client_ws.close()

    try:
        await asyncio.gather(c2u(), u2c())
    except (ConnectionResetError, ConnectionError, asyncio.TimeoutError):
        pass  # incl. the heartbeat ServerTimeoutError when the upstream WS goes silent
    finally:
        # On any exception (including CancelledError) close both ends to avoid leaking the upstream WebSocket connection (C22)
        request.app["websockets"].discard(client_ws)  # untrack (L4)
        if not up_ws.closed:
            await up_ws.close()
        if not client_ws.closed:
            await client_ws.close()
    return client_ws


async def make_app():
    app = web.Application(client_max_size=1024 ** 4)  # effectively unlimited upload size
    app["websockets"] = set()  # open client-side WebSockets, tracked for graceful shutdown (L4)
    # Uncapped connection pool (limit=0): the aiohttp default is 100, and a stalled NFS-backed
    # upstream read holding pooled connections would, once 100 are held, block every further
    # request until they time out. Uncapped keeps healthy requests flowing; sock_read below still
    # reclaims a wedged connection after 600 s (C19).
    connector = aiohttp.TCPConnector(limit=0)
    session = aiohttp.ClientSession(
        connector=connector,
        auto_decompress=False,  # stream upstream compression as-is (slow links still benefit from gzip)
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=600),  # upstream read timeout: prevents coroutines from hanging forever when NFS stalls (C19)
    )
    app["session"] = session

    async def _close(app):
        await session.close()
    app.on_cleanup.append(_close)

    # aiohttp does not close WebSockets on shutdown by itself; close the ones we are tunnelling so a
    # restart (e.g. by the watchdog) tears them down cleanly instead of leaking half-open sockets (L4).
    async def _shutdown(app):
        for ws in set(app["websockets"]):
            try:
                await ws.close(code=1001, message=b"server shutdown")
            except Exception:
                pass
    app.on_shutdown.append(_shutdown)

    app.router.add_route("*", "/{tail:.*}", handle)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=LISTEN_HOST, port=LISTEN_PORT, print=None)
