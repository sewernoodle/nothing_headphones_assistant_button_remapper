@echo off
REM Nothing Headphones (1) button detector - launcher
REM Bypasses PowerShell execution policy and unblocks the script.
REM Forward any arguments to detector.ps1, e.g.:
REM   run.bat -Key A
REM   run.bat -Key "Ctrl+Shift+F13"

setlocal
set "SCRIPT=%~dp0detector.ps1"

REM Strip the Mark-of-the-Web zone identifier so SmartScreen stops nagging
REM after downloads. Silent if the stream isn't there.
powershell -NoProfile -Command "Unblock-File -LiteralPath '%SCRIPT%' -ErrorAction SilentlyContinue" 2>nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

echo.
pause
