@echo off
REM Nothing Headphones (1) - System tray launcher.
REM Hands off to the VBScript launcher so PowerShell starts with no console
REM flash. (For a completely flash-free manual start, double-click
REM launch-hidden.vbs directly instead of this .bat.)

setlocal

REM Unblock to suppress SmartScreen "downloaded from internet" warnings.
powershell -NoProfile -Command "Unblock-File -LiteralPath '%~dp0tray.ps1' -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%~dp0launch-hidden.vbs' -ErrorAction SilentlyContinue" 2>nul

start "" wscript.exe "%~dp0launch-hidden.vbs"

exit
