# Desktop Launcher - launch logic (invoked hidden by launcher.vbs)
# Reads config.txt from the same directory (line1=SSH alias, line2=local port, line3=server identity, line4=remote start command) -> shows a progress window
# -> opens SSH tunnel -> auto-restarts service if down -> opens browser.
# Key: the Connector window IS the session. The tunnel is owned as a child process of this launcher;
# closing the window (or clicking "Disconnect") kills the tunnel and releases the port.
# The console window is hidden by launcher.vbs (no black flash); the window only shows progress and manages the connection.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
try {
  $cfg     = Get-Content (Join-Path $here 'config.txt') -ErrorAction Stop
  $srvHost = $cfg[0].Trim()
  $port    = $cfg[1].Trim()
  $srvId   = if ($cfg.Count -ge 3 -and $cfg[2] -and $cfg[2].Trim()) { $cfg[2].Trim() } else { $srvHost }
} catch {
  [System.Windows.Forms.MessageBox]::Show("Cannot read config.txt. Please re-run install.bat to reinstall.", "Launch Failed") | Out-Null
  return
}
$rport    = 8080
$url      = "http://localhost:$port/"
# config line 4 holds the RAW remote command (no 'bash ' prefix); 'bash ' is added only when running it.
# Keeping the raw form separate is what prevents a double 'bash ' on identity write-back below (L1).
$srvStartRaw = if ($cfg.Count -ge 4 -and $cfg[3] -and $cfg[3].Trim()) { $cfg[3].Trim() } else { '~/filebrowser-ssh-kit/server/start.sh' }
$srvStart    = 'bash ' + $srvStartRaw
$name     = "$srvHost Connector"

# Pre-flight: OpenSSH must be present. Without this, the Start-Process ssh calls below fail silently;
# the tunnel never opens and the user gets a misleading "cannot reach server" after a 10s wait, then is
# told to run 'ssh <alias>' -- which also fails ('ssh' not recognized). Give an actionable message instead.
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  [System.Windows.Forms.MessageBox]::Show("OpenSSH Client is not installed on this PC.`n`nInstall it, then relaunch this Connector:`n  Settings > Apps > Optional Features > Add a feature > OpenSSH Client`n`n(Requires Windows 10 version 1809 or later.)", "$name -- OpenSSH Not Found") | Out-Null
  return
}

# Track the tunnel process: used to implement "close window = disconnect" (only kill tunnels we opened)
$script:ssh        = $null
$script:ownsTunnel = $false

# ---------- Progress / session window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text            = $name
$form.FormBorderStyle = 'FixedDialog'
$form.StartPosition   = 'CenterScreen'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $true
$form.TopMost         = $true
$form.ClientSize      = New-Object System.Drawing.Size(420, 132)
$ico = Join-Path $here 'icon.ico'
if (Test-Path $ico) { try { $form.Icon = New-Object System.Drawing.Icon($ico) } catch {} }

# When the window closes (by any means): if we own the tunnel, kill it (release the port) -- this is "close = disconnect"
# Known limitation (vs the macOS launcher's `trap EXIT`): this handler reaps the tunnel on every normal
# close and on logoff/shutdown, but NOT if the launcher is force-killed (Task Manager "End task") or
# crashes -- ssh.exe is then orphaned holding the local port until reboot. The next launch self-heals
# (occupied port -> X-FB-Server identity check -> reuse or swap to a free port), so the impact is a stray
# process, never a wrong-server connection. A complete fix would assign ssh to a Win32 Job Object
# (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE); deferred (untested-on-Windows P/Invoke, low payoff). The
# Stop-Process below could equivalently be $script:ssh.Kill() (handle-based, immune to PID recycling).
$form.Add_FormClosed({
  if ($script:ownsTunnel -and $script:ssh -and -not $script:ssh.HasExited) {
    try { Stop-Process -Id $script:ssh.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
})

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Connecting to $srvHost"
$lblTitle.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.SetBounds(16, 14, 388, 26)
$form.Controls.Add($lblTitle)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Starting..."
$lblStatus.SetBounds(16, 46, 388, 40)
$form.Controls.Add($lblStatus)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Style = 'Marquee'
$bar.MarqueeAnimationSpeed = 30
$bar.SetBounds(16, 92, 388, 20)
$form.Controls.Add($bar)

$btn = New-Object System.Windows.Forms.Button
$btn.Text    = "Close"
$btn.Visible = $false
$btn.SetBounds(316, 150, 88, 28)
$btn.Add_Click({ $form.Close() })
$form.Controls.Add($btn)

$form.Add_Shown({ $form.Activate() })
$form.Show()
[System.Windows.Forms.Application]::DoEvents()

# Update status text (if the window was closed by the user, exit the entire launcher immediately)
function Step($t) {
  if ($form.IsDisposed) { exit }
  $lblStatus.Text = $t
  [System.Windows.Forms.Application]::DoEvents()
}
# Wait $ms milliseconds while keeping the UI responsive (progress bar animating, window draggable/closable)
function Pump($ms) {
  $end = [DateTime]::Now.AddMilliseconds($ms)
  while ([DateTime]::Now -lt $end) {
    [System.Windows.Forms.Application]::DoEvents()
    if ($form.IsDisposed) { exit }
    Start-Sleep -Milliseconds 30
  }
}
# Failure: write the reason into the same window, stop the progress bar, show a Close button, wait for the user to close
function Fail($t) {
  if ($form.IsDisposed) { exit }
  $bar.Visible        = $false
  $lblTitle.Text      = "Connection Failed"
  $lblTitle.ForeColor = [System.Drawing.Color]::Firebrick
  $lblStatus.SetBounds(16, 46, 388, 116)
  $lblStatus.Text     = $t
  $form.ClientSize    = New-Object System.Drawing.Size(420, 200)
  $btn.Text           = "Close"
  $btn.SetBounds(316, 166, 88, 28)
  $btn.Visible        = $true
  while (-not $form.IsDisposed) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
  exit
}

# ---------- Connectivity / identity probing ----------
# Check whether a local port has a listener (returns $true); times out in 700ms to avoid the default ~21s hang. finally always releases the socket.
function Test-Listen($p) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect('127.0.0.1', [int]$p, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(700)) { $c.EndConnect($iar); return $true }
    return $false
  } catch { return $false }
  finally { $c.Close(); $c.Dispose() }
}
# Read the X-FB-Server identity header from the service on port $p; returns '' if not present.
function Server-Id($p) {
  $h = $null
  try {
    # Use HEAD to fetch only response headers (not the full SPA body) -> works within timeout on slow long-distance links;
    # avoids body read timeout returning empty -> incorrectly treating our own tunnel as "another program" and swapping ports
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -Method Head -TimeoutSec 4 -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
    $h = $r.Headers['X-FB-Server']
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { try { $h = $_.Exception.Response.Headers['X-FB-Server'] } catch { $h = $null } }
  } catch { $h = $null }
  if ($h -is [array]) { $h = $h[0] }
  if ($null -eq $h) { return '' }
  return ([string]$h).Trim()
}
# Find the first local port >= $start with no listener (used during self-heal port swap).
# Returns 0 if every port up to 65535 is occupied (never a valid port) so the caller can report it,
# rather than returning an untested port at the upper cap that the tunnel would then fail to bind.
function Find-FreePort($start) {
  $p = [int]$start
  while ($p -le 65535 -and (Test-Listen $p)) { $p++ }
  if ($p -gt 65535) { return 0 }
  return $p
}
function Svc-Ok {
  try { Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop | Out-Null; return $true }
  catch [System.Net.WebException] {
    # Any response means the port is listening: 2xx/3xx/401/403 = up.
    # Only 5xx (especially 502 from the proxy meaning filebrowser is down) = not up ->
    # triggers the remote start command below, rather than opening the browser to a 502 error page (C2).
    $r = $_.Exception.Response
    if ($r) { try { return ([int]$r.StatusCode -lt 500) } catch { return $true } }
    return $false
  }
  catch { return $false }
}

# ---------- Launch sequence ----------
# 1) Decide which local port to use and whether to open the tunnel ourselves.
#    Key hardening: if the port is already occupied, check whether it belongs to this server (X-FB-Server).
#    Match -> reuse existing tunnel; mismatch (another server's tunnel or an unrelated program) ->
#    find a free port, open our own tunnel, never connect to the wrong host.
Step("Checking local port $port...")
if (Test-Listen $port) {
  $who = Server-Id $port
  if ($who -eq $srvId) {
    Step("Found an existing ready connection, reusing...")
  } else {
    $busyBy = if ($who) { "another server ($who)" } else { "another program" }
    $free = Find-FreePort ([int]$port + 1)
    if ($free -le 0) { Fail("No free local port is available to reach $srvHost.`n`nClose some applications that are using local network ports, then try again.") }
    $port = [string]$free
    Step("Port occupied by $busyBy, switching to free port $port...")
  }
}
$url = "http://localhost:$port/"

# 2) Port is free (or we just switched to a free one): open the tunnel ourselves.
#    -PassThru keeps the ssh child process object so we can kill exactly this tunnel when the window closes.
if (-not (Test-Listen $port)) {
  Step("Opening SSH tunnel (local port $port)...")
  # ServerAliveCountMax=6: an established tunnel tolerates ~90s (15x6) of silence before being declared dead, so brief jitter self-heals; a truly dead tunnel is handled by the auto-reconnect session loop below.
  $script:ssh = Start-Process ssh -PassThru -WindowStyle Hidden -ArgumentList @("-N","-o","ConnectTimeout=8","-o","BatchMode=yes","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=6","-o","ExitOnForwardFailure=yes","-L","${port}:127.0.0.1:${rport}","$srvHost")
  $script:ownsTunnel = $true
  Step("Waiting for port to become ready...")
  # Wait > ssh ConnectTimeout (8s) above so we never give up while ssh is still legitimately connecting (M4): 40 * 250ms = 10s.
  for ($i = 0; $i -lt 40 -and -not (Test-Listen $port); $i++) { Pump 250 }
  if (-not (Test-Listen $port)) {
    Fail("Cannot reach server ($srvHost).`n`nVerify that the following works in PowerShell first:`n    ssh $srvHost`n(First time: run that in PowerShell and type yes to accept the host key -- this launcher can't prompt. Also confirm key-based (passwordless) login works.)")
  }
}

# C12/C9: After opening the tunnel, treat the server's own X-FB-Server header as the authoritative identity
# (the SSH alias may differ from the server's self-reported name). Learn and write back to config line 3
# for future sessions -- port reuse works correctly regardless of the alias name.
if ($script:ownsTunnel) {
  $who2 = Server-Id $port
  if ($who2 -and $who2 -ne $srvId) {
    $srvId = $who2
    try { Set-Content -Path (Join-Path $here 'config.txt') -Value @($srvHost, $cfg[1].Trim(), $srvId, $srvStartRaw) -Encoding ascii -ErrorAction Stop } catch {}
  }
}

# 3) Start the service remotely if it is not responding
Step("Checking file service...")
if (-not (Svc-Ok)) {
  Step("Starting file service...")
  Start-Process ssh -WindowStyle Hidden -ArgumentList @("-o","ConnectTimeout=8","-o","BatchMode=yes","$srvHost","$srvStart")
  # Allow up to ~18s: covers server-side start.sh which may itself wait up to ~10s; polling keeps the UI responsive
  for ($i = 0; $i -lt 60 -and -not (Svc-Ok); $i++) { Pump 300 }
}

# 4) Open the browser
if (Svc-Ok) {
  $bar.Style = 'Continuous'; $bar.Value = 100
  $lblTitle.Text = "Connected to $srvHost"
  Step("Opening browser...")
  Start-Process $url
  if ($script:ownsTunnel) {
    # Session mode: window open = connection alive; close it (or click "Disconnect") = tunnel killed, port released.
    $bar.Visible    = $false
    $lblStatus.Text = "Local port $port - close this window to disconnect (closing the browser does not disconnect)"
    $btn.Text       = "Disconnect"
    $btn.SetBounds(150, 92, 120, 30)
    $btn.Visible    = $true
    $form.TopMost   = $false
    # Session loop + auto-reconnect: window closed = user disconnected (FormClosed kills the current tunnel);
    # ssh child exits = tunnel died mid-session (sleep / jitter / network drop) -> automatically rebuild the tunnel
    # with backoff (same port; the open browser tab needs no URL change), instead of asking the user to relaunch.
    # Reconnect progress/success/failure is shown in the same window. $script:ssh always points at the latest tunnel.
    $reDelay = 2
    while (-not $form.IsDisposed) {
      if ($script:ssh -and -not $script:ssh.HasExited) {
        # Tunnel healthy: if we just recovered from a reconnect, restore the "Connected" title/status
        if ($lblTitle.Text -ne "Connected to $srvHost") {
          $lblTitle.Text      = "Connected to $srvHost"
          $lblTitle.ForeColor = [System.Drawing.SystemColors]::ControlText
          $lblStatus.Text     = "Local port $port - close this window to disconnect (closing the browser does not disconnect; auto-reconnects on network drop)"
        }
        $reDelay = 2
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
        continue
      }
      # -- tunnel dropped -> auto-reconnect --
      $lblTitle.Text      = "Reconnecting..."
      $lblTitle.ForeColor = [System.Drawing.Color]::DarkOrange
      $lblStatus.Text     = "Network drop or sleep closed the tunnel; reconnecting to $srvHost (local port $port)..."
      [System.Windows.Forms.Application]::DoEvents()
      $script:ssh = Start-Process ssh -PassThru -WindowStyle Hidden -ArgumentList @("-N","-o","ConnectTimeout=8","-o","BatchMode=yes","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=6","-o","ExitOnForwardFailure=yes","-L","${port}:127.0.0.1:${rport}","$srvHost")
      # Wait for the port to become ready (~10s); the window stays closable (close -> IsDisposed -> break out)
      $ok = $false
      for ($i = 0; $i -lt 40 -and -not $form.IsDisposed; $i++) {
        if (Test-Listen $port) { $ok = $true; break }
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250
      }
      if ($form.IsDisposed) { break }
      if (-not $ok) {
        # This attempt failed -> reap it and back off before retrying (2 -> 4 -> ... -> 30s cap)
        if ($script:ssh -and -not $script:ssh.HasExited) { try { Stop-Process -Id $script:ssh.Id -Force -ErrorAction SilentlyContinue } catch {} }
        $lblStatus.Text = "Reconnect failed, retrying in $reDelay s... (close the window to give up)"
        for ($i = 0; $i -lt ($reDelay * 10) -and -not $form.IsDisposed; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $reDelay = [Math]::Min($reDelay * 2, 30)
      }
    }
    exit
  } else {
    # Reusing an existing tunnel opened by another instance: give brief feedback then close; do not touch the tunnel we did not open.
    $lblStatus.Text = "Reusing existing connection, opening browser..."
    Pump 1000
    if (-not $form.IsDisposed) { $form.Close() }
  }
} else {
  Fail("Tunnel is up but the file service on the server did not start.`nRun manually on the server:`n    $srvStart")
}
