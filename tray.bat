@echo off
REM Nothing Headphones (1) - System tray launcher
REM Starts tray.ps1 hidden so it lives only in the system tray.

setlocal
set "SCRIPT=%~dp0tray.ps1"

REM Unblock to suppress SmartScreen "downloaded from internet" warnings.
powershell -NoProfile -Command "Unblock-File -LiteralPath '%SCRIPT%' -ErrorAction SilentlyContinue" 2>nul

REM Launch hidden. The PS1 also hides its console internally, so even on
REM the brief flicker before that runs, nothing visible should remain.
start "" /B powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*

exit
