' Server Connector - hidden launcher (invoked by the desktop shortcut).
' Runs under wscript (no console), then starts launcher.ps1 hidden, so there is no black-window flash.
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "launcher.ps1""", 0, False
