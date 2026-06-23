# Desktop Launcher - Windows Installer
# Purpose: prompts for SSH alias + port -> installs the launcher to %LOCALAPPDATA%\file-launcher ->
#          creates a desktop shortcut (custom icon + hidden window, no black console flash).
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconSrc = Join-Path $here '..\icon\icon.ico'
if (-not (Test-Path $iconSrc)) {
  [System.Windows.Forms.MessageBox]::Show("Icon file not found:`n$iconSrc`nPlease make sure you extracted the entire folder before running the installer (do not copy only the windows subdirectory).", "Installation Failed") | Out-Null
  return
}
$icon = (Resolve-Path $iconSrc).Path

$srvHost = [Microsoft.VisualBasic.Interaction]::InputBox("Server SSH alias (the name you type after ssh in your terminal):", "Install Server Connector", "myserver")
if ([string]::IsNullOrWhiteSpace($srvHost)) { $srvHost = "myserver" }
$srvHost = $srvHost.Trim()
# Only standard SSH Host characters are allowed. Any other character would break directory names, shortcuts, and tunnel arguments.
# Reject and exit rather than silently producing a broken install (consistent with the macOS installer).
if ($srvHost -notmatch '^[A-Za-z0-9._-]+$') {
  [System.Windows.Forms.MessageBox]::Show("The alias contains special characters and cannot be used safely.`nPlease use an alias containing only letters, digits, . _ - (e.g. myserver).", "Installation Failed") | Out-Null
  return
}
$name = "$srvHost Connector"   # shortcut name = server alias + Connector (avoids collisions with local app names)

# Each server is installed into its own subdirectory so configs and ports never overwrite each other.
$base = Join-Path $env:LOCALAPPDATA 'file-launcher'
$dest = Join-Path $base $srvHost

# Automatically pick a local port not already used by another installed server: scan config files (line 2 = port).
# Different servers need different local ports; otherwise whichever one grabs the port first is what every double-click connects to.
# Collect via pipeline output rather than += inside ForEach-Object (which cannot write to outer scope variables).
$used = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne $srvHost } | ForEach-Object {
    $cf = Join-Path $_.FullName 'config.txt'
    if (Test-Path $cf) { $line = (Get-Content $cf)[1]; if ($line) { $line.Trim() } }
  })
# Default port is derived from the alias to avoid the crowded 8080 range (8300-9299).
$h = 0
foreach ($ch in $srvHost.ToCharArray()) { $h = ($h * 131 + [int]$ch) % 1000 }
$suggest = 8300 + $h
while ($used -contains [string]$suggest) { $suggest++ }

$port = [Microsoft.VisualBasic.Interaction]::InputBox("Local port (must be unique per server; an idle port has been pre-selected -- just accept it):", "Install Server Connector", [string]$suggest)
if ($port -notmatch '^\d+$') { $port = [string]$suggest }   # empty or non-numeric -> fall back to auto-selected port
$port = $port.Trim()
if ($used -contains $port) {
  [System.Windows.Forms.MessageBox]::Show("Port $port is already used by another installed server.`nConsider using the auto-selected port $suggest instead.`n`nIf you keep $port, do not use both servers at the same time or you may connect to the wrong one.", "Port Warning") | Out-Null
}

$srvStart = [Microsoft.VisualBasic.Interaction]::InputBox("Remote command to start the service:", "Install Server Connector", "~/filebrowser-ssh-kit/server/start.sh")
if ([string]::IsNullOrWhiteSpace($srvStart)) { $srvStart = "~/filebrowser-ssh-kit/server/start.sh" }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $here 'launcher.ps1') (Join-Path $dest 'launcher.ps1') -Force
Copy-Item (Join-Path $here 'launcher.vbs') (Join-Path $dest 'launcher.vbs') -Force
Copy-Item $icon (Join-Path $dest 'icon.ico') -Force
# Config: line 1 = alias, line 2 = local port, line 3 = identity token (= alias; launcher verifies against X-FB-Server), line 4 = remote start command
Set-Content -Path (Join-Path $dest 'config.txt') -Value @($srvHost, $port, $srvHost, $srvStart) -Encoding ascii

# Desktop shortcut -> wscript runs launcher.vbs hidden (no black window)
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop "$name.lnk"
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath       = "$env:WINDIR\System32\wscript.exe"
$lnk.Arguments        = '"' + (Join-Path $dest 'launcher.vbs') + '"'
$lnk.WorkingDirectory = $dest
$lnk.IconLocation     = (Join-Path $dest 'icon.ico') + ",0"
$lnk.Description       = "Connect and open $srvHost"
$lnk.WindowStyle      = 7
$lnk.Save()

[System.Windows.Forms.MessageBox]::Show("OK: '$name' shortcut created on your Desktop (local port $port).`n`nDouble-click it anytime to connect -- no terminal or manual commands needed.`nMultiple servers each use their own port and can be open simultaneously.", "Installation Complete") | Out-Null
