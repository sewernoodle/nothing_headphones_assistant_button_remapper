# Nothing Headphones (1) - Button-press Detector + Key Mapper
#
# Single-file portable detector. Auto-discovers tshark.exe and tries each
# USBPcap interface until one yields Bluetooth traffic.
#
# Requirements on the target machine:
#   - Wireshark installed (any recent version, any location)
#   - USBPcap installed (bundled with the Wireshark installer)
#   - A Bluetooth USB dongle with the headphones paired
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\detector.ps1
#   powershell -ExecutionPolicy Bypass -File .\detector.ps1 -Key "A"
#   powershell -ExecutionPolicy Bypass -File .\detector.ps1 -Key "Ctrl+Shift+F13"
#   powershell -ExecutionPolicy Bypass -File .\detector.ps1 -Interface "\\.\USBPcap2"
#
# Supported keys (case-insensitive):
#   F1..F24, A..Z, 0..9, Space, Enter, Tab, Esc, Backspace
#   Modifiers (combine with +): Ctrl, Shift, Alt, Win

param(
    [string]$Key       = "F13",
    [string]$Interface = "",          # blank = auto-detect
    [string]$Tshark    = ""           # blank = auto-detect
)

$ErrorActionPreference = "Continue"

# Validate -Interface: it is written verbatim into a cmd.exe batch file, so it
# must not contain shell metacharacters. Only "\\.\USBPcapN" is ever valid.
if ($Interface -and $Interface -notmatch '^\\\\\.\\USBPcap\d+$') {
    Write-Host "Invalid -Interface value. Expected something like \\.\USBPcap1" -ForegroundColor Red
    exit 1
}

# ---- Auto-detect tshark.exe -------------------------------------------------
function Find-Tshark {
    if ($Tshark -and (Test-Path $Tshark)) { return $Tshark }
    $candidate = @(
        "C:\Program Files\Wireshark\tshark.exe",
        "C:\Program Files (x86)\Wireshark\tshark.exe",
        "$env:ProgramFiles\Wireshark\tshark.exe",
        "${env:ProgramFiles(x86)}\Wireshark\tshark.exe",
        "$env:LOCALAPPDATA\Programs\Wireshark\tshark.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($candidate) { return $candidate }
    # Try PATH
    $cmd = Get-Command tshark.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$tshark = Find-Tshark
if (-not $tshark) {
    Write-Host "tshark.exe not found. Install Wireshark from https://www.wireshark.org/" -ForegroundColor Red
    Write-Host "(or pass -Tshark <full path>)" -ForegroundColor Yellow
    exit 1
}
Write-Host "Using tshark: $tshark" -ForegroundColor DarkGray

# ---- Auto-detect USBPcap interface ------------------------------------------
# Probes each USBPcap interface briefly; picks the first one with Bluetooth
# traffic. Falls back to USBPcap1 if none have active BT.
function Find-BluetoothInterface {
    Write-Host "Probing USBPcap interfaces for Bluetooth traffic..." -ForegroundColor DarkGray
    for ($n = 1; $n -le 4; $n++) {
        $iface = "\\.\USBPcap$n"
        $cmd = "`"$tshark`" -i $iface -a duration:3 -q -z io,phs 2>nul"
        $out = & cmd /c $cmd 2>$null | Out-String
        if ($out -match 'bluetooth\s+frames:\s*[1-9]') {
            Write-Host "  Found Bluetooth on $iface" -ForegroundColor DarkGray
            return $iface
        }
    }
    Write-Host "  No active Bluetooth seen, defaulting to \\.\USBPcap1" -ForegroundColor DarkGray
    return "\\.\USBPcap1"
}

if (-not $Interface) {
    $Interface = Find-BluetoothInterface
}

# ---- Virtual key code table -------------------------------------------------
$VK = @{}
$VK['CTRL']  = 0xA2; $VK['CONTROL'] = 0xA2; $VK['LCTRL']  = 0xA2; $VK['RCTRL']  = 0xA3
$VK['SHIFT'] = 0xA0; $VK['LSHIFT']  = 0xA0; $VK['RSHIFT'] = 0xA1
$VK['ALT']   = 0xA4; $VK['LALT']    = 0xA4; $VK['RALT']   = 0xA5
$VK['WIN']   = 0x5B; $VK['LWIN']    = 0x5B; $VK['RWIN']   = 0x5C
$VK['SPACE'] = 0x20; $VK['ENTER']   = 0x0D; $VK['TAB']    = 0x09
$VK['ESC']   = 0x1B; $VK['ESCAPE']  = 0x1B; $VK['BACKSPACE'] = 0x08
1..24    | ForEach-Object { $VK["F$_"]            = 0x6F + $_ }   # F1=0x70..F24=0x87
65..90   | ForEach-Object { $VK[[string][char]$_] = $_ }          # A-Z
48..57   | ForEach-Object { $VK[[string][char]$_] = $_ }          # 0-9

function Parse-Key {
    param([string]$spec)
    $parts = $spec -split '\+' | ForEach-Object { $_.Trim().ToUpper() }
    $codes = @()
    foreach ($p in $parts) {
        if ($VK.ContainsKey($p)) { $codes += [byte]$VK[$p] }
        else { throw "Unknown key: '$p'" }
    }
    return ,$codes
}

try {
    $keyCodes = Parse-Key $Key
} catch {
    Write-Host "Invalid -Key value '$Key': $_" -ForegroundColor Red
    Write-Host "Examples: F13, Ctrl+Shift+F13, Alt+M, Win+P" -ForegroundColor Yellow
    exit 1
}

# ---- Keyboard simulation via Win32 keybd_event ------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Kbd {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public const uint KEYDOWN = 0x0000;
    public const uint KEYUP   = 0x0002;
    public static void Down(byte vk) { keybd_event(vk, 0, KEYDOWN, UIntPtr.Zero); }
    public static void Up(byte vk)   { keybd_event(vk, 0, KEYUP,   UIntPtr.Zero); }
}
"@ -ErrorAction SilentlyContinue

function Tap-Combo {
    foreach ($c in $keyCodes) { [Kbd]::Down($c) }
    Start-Sleep -Milliseconds 20
    for ($i = $keyCodes.Count - 1; $i -ge 0; $i--) { [Kbd]::Up($keyCodes[$i]) }
}

# ---- Spawn capture pipe -----------------------------------------------------
# Kill ONLY this tool's leftover capture pipelines from a previous crashed run
# (identified by our uniquely-named batch file / unique display filter).
# This never touches a Wireshark capture the user started for other purposes.
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'nothing_(tray|detector)_pipe_\d+\.bat' } |
    ForEach-Object {
        $cmdPid = $_.ProcessId
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$cmdPid" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $cmdPid -Force -ErrorAction SilentlyContinue
    }
Get-CimInstance Win32_Process -Filter "Name='tshark.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'btl2cap\.payload' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300

$outFile = Join-Path $env:TEMP "nothing_detector_out_$PID.txt"
$errFile = Join-Path $env:TEMP "nothing_detector_err_$PID.txt"
Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
New-Item -ItemType File -Path $outFile -Force | Out-Null

# Build the cmd pipe: capture-only tshark | dissecting tshark
# Written to a temp .bat file because Start-Process quoting of complex
# inline commands is unreliable. The pipe runs under cmd.exe to safely
# transport binary pcap data between the two tshark processes.
$filter = 'btl2cap and (' +
          'frame contains 11:0e:00:48:7c or ' +
          'frame contains 41:54:2b:42:56:52:41:3d or ' +
          'frame contains 11:0e:0d:48:00:00:19:58:31)'

$batFile = Join-Path $env:TEMP "nothing_detector_pipe_$PID.bat"
@"
@echo off
"$tshark" -i $Interface -w - | "$tshark" -r - -l -Q -Y "$filter" -T fields -e btl2cap.payload
"@ | Set-Content -Path $batFile -Encoding ASCII

Write-Host "Spawning capture pipe on $Interface ..." -ForegroundColor Cyan
$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batFile`"" `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
    -WindowStyle Hidden -PassThru

Start-Sleep -Milliseconds 1500
if ($proc.HasExited) {
    Write-Host "Capture pipe exited immediately. stderr:" -ForegroundColor Red
    Get-Content $errFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Listening for Nothing Headphones (1) voice assistant button..." -ForegroundColor Cyan
Write-Host "Each tap of the headphone button = one '$Key' keystroke." -ForegroundColor Cyan
Write-Host "Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

function Parse-Payload {
    param([string]$hex)
    $hex = $hex.ToLower() -replace '[:\s]', ''
    if (-not $hex) { return $null }

    if ($hex -match '110e00487c([0-9a-f]{2})') {
        $b = [Convert]::ToInt32($matches[1], 16)
        $pressed = ($b -band 0x80) -eq 0
        $op = '{0:x2}' -f ($b -band 0x7f)
        $n = switch ($op) {
            '44' { 'PLAY' } '45' { 'STOP' } '46' { 'PAUSE' }
            '4b' { 'NEXT TRACK' } '4c' { 'PREV TRACK' }
            '41' { 'VOLUME UP' } '42' { 'VOLUME DOWN' }
            default { "AVRCP op=0x$op" }
        }
        $tag = if ($pressed) { 'pressed' } else { 'released' }
        return @{ label = "$n ($tag)"; voice = $false }
    }
    elseif ($hex -match '110e0d4800001958310.+0d([0-9a-f]{2})') {
        $v = [Convert]::ToInt32($matches[1], 16)
        $pct = [Math]::Round(100 * $v / 127)
        return @{ label = "VOLUME = $v/127 ($pct" + "%)"; voice = $false }
    }
    elseif ($hex -match '41542b425652413d31') {
        return @{ label = "VOICE BUTTON (state=ON)";  voice = $true }
    }
    elseif ($hex -match '41542b425652413d30') {
        return @{ label = "VOICE BUTTON (state=OFF)"; voice = $true }
    }
    return $null
}

$reader = [System.IO.StreamReader]::new(
    [System.IO.File]::Open($outFile, 'Open', 'Read', 'ReadWrite'))

try {
    while (-not $proc.HasExited -or -not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            Start-Sleep -Milliseconds 50
            continue
        }
        $r = Parse-Payload $line
        if (-not $r) { continue }

        if ($r.voice) {
            Tap-Combo
            Write-Host ("[{0:HH:mm:ss}] {1}  -> tapped '{2}'" -f (Get-Date), $r.label, $Key) -ForegroundColor Green
        } else {
            $color = if ($r.label -match 'OFF|released|STOP|PAUSE|DOWN') { 'Yellow' } else { 'Cyan' }
            Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $r.label) -ForegroundColor $color
        }
    }
}
finally {
    $reader.Close()
    if (-not $proc.HasExited) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $outFile, $errFile, $batFile -ErrorAction SilentlyContinue
}
