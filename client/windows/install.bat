@echo off
REM Server Connector - Windows installer entry. Double-click this file.
REM It just launches install.ps1 (which shows the install dialogs and makes the desktop shortcut).
echo Installing the Server Connector desktop shortcut...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo Done. You can close this window.
pause >nul
