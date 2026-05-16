# Nothing Headphones (1) - System Tray App (modern UI)
# Custom popup with rounded corners and macOS-style hover effects, plus
# Windows 11 Mica/acrylic backdrop where available.

param(
    [string]$Key       = "F13",
    [string]$Interface = "",
    [string]$Tshark    = ""
)

$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Validate -Interface: it is written verbatim into a cmd.exe batch file, so it
# must not contain shell metacharacters. Only "\\.\USBPcapN" is ever valid.
if ($Interface -and $Interface -notmatch '^\\\\\.\\USBPcap\d+$') {
    [System.Windows.Forms.MessageBox]::Show(
        "Invalid -Interface value.`nExpected something like \\.\USBPcap1",
        "Nothing Headphones Detector") | Out-Null
    exit 1
}

# ---- Native helpers (rounded corners, dark mode, Mica, console hide) ------
Add-Type -Name Native -Namespace TrayApp -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("Gdi32.dll")]
public static extern System.IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction SilentlyContinue

# Hide our own console
$hwndConsole = [TrayApp.Native]::GetConsoleWindow()
if ($hwndConsole -ne [IntPtr]::Zero) { [TrayApp.Native]::ShowWindow($hwndConsole, 0) | Out-Null }

# ---- Theme -----------------------------------------------------------------
$Theme = @{
    BgPanel     = [System.Drawing.Color]::FromArgb(38, 38, 42)
    BgHover     = [System.Drawing.Color]::FromArgb(60, 60, 70)
    BgPressed   = [System.Drawing.Color]::FromArgb(80, 80, 90)
    Separator   = [System.Drawing.Color]::FromArgb(70, 70, 75)
    TextPrimary = [System.Drawing.Color]::FromArgb(240, 240, 240)
    TextMuted   = [System.Drawing.Color]::FromArgb(150, 150, 155)
    Accent      = [System.Drawing.Color]::FromArgb(10, 132, 255)
    AccentText  = [System.Drawing.Color]::White
    Danger      = [System.Drawing.Color]::FromArgb(255, 95, 87)
}
$FontFamily = "Segoe UI Variable Display"
try {
    $null = New-Object System.Drawing.Font($FontFamily, 9)
} catch {
    $FontFamily = "Segoe UI"
}
$FontReg    = New-Object System.Drawing.Font($FontFamily, 10)
$FontBold   = New-Object System.Drawing.Font($FontFamily, 10, [System.Drawing.FontStyle]::Bold)
$FontMuted  = New-Object System.Drawing.Font($FontFamily, 9)

function Set-WindowRoundedDark {
    param([System.Windows.Forms.Form]$form, [int]$radius = 12)
    $d = $radius * 2
    $form.Region = [System.Drawing.Region]::FromHrgn(
        [TrayApp.Native]::CreateRoundRectRgn(0, 0, $form.Width + 1, $form.Height + 1, $d, $d))
    try {
        $hwnd = $form.Handle
        $one = 1
        [TrayApp.Native]::DwmSetWindowAttribute($hwnd, 20, [ref]$one, 4) | Out-Null  # dark title bar
        $round = 2
        [TrayApp.Native]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4) | Out-Null # rounded corners (Win11)
        $mica = 2
        [TrayApp.Native]::DwmSetWindowAttribute($hwnd, 38, [ref]$mica, 4) | Out-Null  # Mica backdrop (Win11)
    } catch {}
}

# ---- Keyboard simulation ---------------------------------------------------
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

$VK = @{}
$VK['CTRL']  = 0xA2; $VK['CONTROL'] = 0xA2; $VK['LCTRL']  = 0xA2; $VK['RCTRL']  = 0xA3
$VK['SHIFT'] = 0xA0; $VK['LSHIFT']  = 0xA0; $VK['RSHIFT'] = 0xA1
$VK['ALT']   = 0xA4; $VK['LALT']    = 0xA4; $VK['RALT']   = 0xA5
$VK['WIN']   = 0x5B; $VK['LWIN']    = 0x5B; $VK['RWIN']   = 0x5C
$VK['SPACE'] = 0x20; $VK['ENTER']   = 0x0D; $VK['TAB']    = 0x09
$VK['ESC']   = 0x1B; $VK['ESCAPE']  = 0x1B; $VK['BACKSPACE'] = 0x08
1..24    | ForEach-Object { $VK["F$_"]            = 0x6F + $_ }
65..90   | ForEach-Object { $VK[[string][char]$_] = $_ }
48..57   | ForEach-Object { $VK[[string][char]$_] = $_ }

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

function Tap-Combo {
    param([byte[]]$codes)
    foreach ($c in $codes) { [Kbd]::Down($c) }
    Start-Sleep -Milliseconds 20
    for ($i = $codes.Count - 1; $i -ge 0; $i--) { [Kbd]::Up($codes[$i]) }
}

# ---- tshark discovery + auto-detect ---------------------------------------
function Find-Tshark {
    if ($script:Tshark -and (Test-Path $script:Tshark)) { return $script:Tshark }
    # Use Select-Object -First 1 to avoid the "single string returned from
    # pipeline gets indexed character-by-character" PowerShell gotcha.
    $cand = @(
        "C:\Program Files\Wireshark\tshark.exe",
        "C:\Program Files (x86)\Wireshark\tshark.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($cand) { return $cand }
    $c = Get-Command tshark.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Find-BluetoothInterface {
    param([string]$ts)
    for ($n = 1; $n -le 4; $n++) {
        $iface = "\\.\USBPcap$n"
        $cmd = "`"$ts`" -i $iface -a duration:3 -q -z io,phs 2>nul"
        $out = & cmd /c $cmd 2>$null | Out-String
        if ($out -match 'bluetooth\s+frames:\s*[1-9]') { return $iface }
    }
    return "\\.\USBPcap1"
}

# ---- Config persistence + autostart ---------------------------------------
$script:ConfigDir     = Join-Path $env:APPDATA "NothingHeadphonesDetector"
$script:ConfigFile    = Join-Path $script:ConfigDir "config.json"
$script:AutostartKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:AutostartName = "NothingHeadphonesDetector"
$script:ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SelfPs1       = Join-Path $script:ScriptDir "tray.ps1"

# The autostart command launches PowerShell directly (no .bat middleman, which
# would tear down its own console and could kill the hidden child at login).
$script:PsExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path $script:PsExe)) {
    $script:PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}
$script:AutostartCmd = "`"$($script:PsExe)`" -NoProfile -ExecutionPolicy Bypass " +
                       "-WindowStyle Hidden -File `"$($script:SelfPs1)`""

function Save-Config {
    try {
        if (-not (Test-Path $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        @{ key = $script:currentKey } | ConvertTo-Json | Set-Content $script:ConfigFile -Encoding UTF8
    } catch {}
}

function Load-Config {
    if (Test-Path $script:ConfigFile) {
        try {
            $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
            if ($cfg.key) { return $cfg.key }
        } catch {}
    }
    return $null
}

function Is-AutostartEnabled {
    try {
        $val = Get-ItemPropertyValue -Path $script:AutostartKey -Name $script:AutostartName -ErrorAction Stop
        return -not [string]::IsNullOrEmpty($val)
    } catch { return $false }
}

function Enable-Autostart {
    try {
        Set-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -Value $script:AutostartCmd -ErrorAction Stop
        return $true
    } catch { return $false }
}

# If autostart is on but still points at the old tray.bat entry, silently
# upgrade it to the direct-PowerShell command.
function Repair-Autostart {
    try {
        $val = Get-ItemPropertyValue -Path $script:AutostartKey -Name $script:AutostartName -ErrorAction Stop
        if ($val -and $val -ne $script:AutostartCmd) {
            Set-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -Value $script:AutostartCmd
        }
    } catch {}
}

function Disable-Autostart {
    try {
        Remove-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -ErrorAction Stop
        return $true
    } catch { return $false }
}

if (-not $PSBoundParameters.ContainsKey('Key')) {
    $saved = Load-Config
    if ($saved) { $Key = $saved }
}

$script:tshark = Find-Tshark
if (-not $script:tshark) {
    [System.Windows.Forms.MessageBox]::Show(
        "tshark.exe not found.`n`nInstall Wireshark from https://www.wireshark.org/`n(check the USBPcap option during install)",
        "Nothing Headphones Detector") | Out-Null
    exit 1
}

# ---- Mutable state ---------------------------------------------------------
$script:currentKey = $Key
$script:keyCodes   = @()
try { $script:keyCodes = Parse-Key $Key } catch {
    [System.Windows.Forms.MessageBox]::Show("Invalid key '$Key': $_", "Nothing Headphones Detector") | Out-Null
    exit 1
}
$script:paused     = $false
$script:tsharkProc = $null
$script:reader     = $null
$script:outFile    = $null
$script:errFile    = $null
$script:batFile    = $null

# ---- Capture management ----------------------------------------------------
$btFilter = 'btl2cap and (' +
            'frame contains 41:54:2b:42:56:52:41:3d or ' +
            'frame contains 11:0e:00:48:7c or ' +
            'frame contains 11:0e:0d:48:00:00:19:58:31)'

# Kill ONLY this tool's leftover capture pipelines from a previous crashed run.
# Identified by our uniquely-named batch file (cmd.exe) and our unique display
# filter (tshark) - never touches a Wireshark capture the user started.
function Stop-OrphanCaptures {
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
}

function Start-Capture {
    Stop-OrphanCaptures
    Start-Sleep -Milliseconds 200

    if (-not $script:Interface) {
        $script:Interface = Find-BluetoothInterface $script:tshark
    }

    $script:outFile = Join-Path $env:TEMP "nothing_tray_out_$PID.txt"
    $script:errFile = Join-Path $env:TEMP "nothing_tray_err_$PID.txt"
    $script:batFile = Join-Path $env:TEMP "nothing_tray_pipe_$PID.bat"
    Remove-Item $script:outFile, $script:errFile, $script:batFile -ErrorAction SilentlyContinue
    New-Item -ItemType File -Path $script:outFile -Force | Out-Null

    # Note: $script:var inside heredoc interpolation can mis-parse; use locals.
    $tsExe = $script:tshark
    $ifc   = $script:Interface
    $flt   = $btFilter
    $bat   = "@echo off`r`n`"$tsExe`" -i $ifc -w - | `"$tsExe`" -r - -l -Q -Y `"$flt`" -T fields -e btl2cap.payload`r`n"
    Set-Content -Path $script:batFile -Value $bat -Encoding ASCII

    $script:tsharkProc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "`"$($script:batFile)`"" `
        -RedirectStandardOutput $script:outFile `
        -RedirectStandardError  $script:errFile `
        -WindowStyle Hidden -PassThru

    Start-Sleep -Milliseconds 1000
    $script:reader = [System.IO.StreamReader]::new(
        [System.IO.File]::Open($script:outFile, 'Open', 'Read', 'ReadWrite'))
}

function Stop-Capture {
    if ($script:reader) { try { $script:reader.Close() } catch {}; $script:reader = $null }
    if ($script:tsharkProc -and -not $script:tsharkProc.HasExited) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($script:tsharkProc.Id)" -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Id $script:tsharkProc.Id -Force -ErrorAction SilentlyContinue
    }
    # Sweep up anything ours that escaped the parent/child kill above.
    Stop-OrphanCaptures
    Remove-Item $script:outFile, $script:errFile, $script:batFile -ErrorAction SilentlyContinue
}

# ---- Custom styled menu item builder --------------------------------------
function New-MenuItem {
    param(
        [string]$text,
        [scriptblock]$onClick,
        [string]$right = "",
        [bool]$enabled = $true,
        [bool]$danger  = $false
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width  = 248
    $panel.Height = 34
    $panel.BackColor = $Theme.BgPanel
    $panel.Margin = New-Object System.Windows.Forms.Padding(4, 1, 4, 1)
    if ($enabled) { $panel.Cursor = [System.Windows.Forms.Cursors]::Hand }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text  = $text
    $lbl.Font  = $FontReg
    $lbl.ForeColor = if (-not $enabled) { $Theme.TextMuted } elseif ($danger) { $Theme.Danger } else { $Theme.TextPrimary }
    $lbl.Dock = "Fill"
    $lbl.TextAlign = "MiddleLeft"
    $lbl.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    $lbl.BackColor = [System.Drawing.Color]::Transparent

    # Labels CAN have transparent BackColor (the Panel-not-supporting issue
    # earlier was specifically about Panel/FlowLayoutPanel controls).
    $lbl.BackColor = [System.Drawing.Color]::Transparent

    # Always create the right-side label so callers can update it later.
    $rightLbl = New-Object System.Windows.Forms.Label
    $rightLbl.Text = $right
    $rightLbl.Font = $FontBold
    $rightLbl.ForeColor = $Theme.Accent
    $rightLbl.AutoSize = $false
    $rightLbl.Dock = "Right"
    $rightLbl.Width = 32
    $rightLbl.TextAlign = "MiddleCenter"
    $rightLbl.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($rightLbl)
    $panel.Controls.Add($lbl)

    if ($enabled) {
        $panelRef = $panel
        $enter = { $panelRef.BackColor = $Theme.BgHover }.GetNewClosure()
        $leave = { $panelRef.BackColor = $Theme.BgPanel }.GetNewClosure()
        $panel.Add_MouseEnter($enter); $panel.Add_MouseLeave($leave)
        $lbl.Add_MouseEnter($enter);   $lbl.Add_MouseLeave($leave)
        $rightLbl.Add_MouseEnter($enter); $rightLbl.Add_MouseLeave($leave)
        if ($onClick) {
            $panel.Add_Click($onClick)
            $lbl.Add_Click($onClick)
            $rightLbl.Add_Click($onClick)
        }
    }
    return @{ Panel = $panel; Label = $lbl; Right = $rightLbl }
}

function New-Separator {
    $p = New-Object System.Windows.Forms.Panel
    $p.Height = 1; $p.Width = 232
    $p.BackColor = $Theme.Separator
    $p.Margin = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
    return $p
}

# ---- Build the popup form -------------------------------------------------
$popup = New-Object System.Windows.Forms.Form
$popup.FormBorderStyle = "None"
$popup.ShowInTaskbar   = $false
$popup.TopMost         = $true
$popup.StartPosition   = "Manual"
$popup.BackColor       = $Theme.BgPanel
$popup.Padding         = New-Object System.Windows.Forms.Padding(6, 8, 6, 8)
$popup.Size            = New-Object System.Drawing.Size(260, 320)

$container = New-Object System.Windows.Forms.FlowLayoutPanel
$container.Dock = "Fill"
$container.FlowDirection = "TopDown"
$container.WrapContents = $false
$container.AutoSize = $true
$container.AutoSizeMode = "GrowAndShrink"
$container.BackColor = $Theme.BgPanel
$popup.Controls.Add($container)

# Title row
$title = New-Object System.Windows.Forms.Label
$title.Text = "Nothing Headphones (1)"
$title.Font = $FontBold
$title.ForeColor = $Theme.TextPrimary
$title.AutoSize = $false
$title.Width = 248
$title.Height = 28
$title.TextAlign = "MiddleLeft"
$title.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
$title.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 0)
$container.Controls.Add($title)

# Key info row
$keyInfo = New-MenuItem -text "Key: $($script:currentKey)" -enabled $false
$container.Controls.Add($keyInfo.Panel)

# Interface info row
$ifInfo = New-MenuItem -text "Interface: ..." -enabled $false
$container.Controls.Add($ifInfo.Panel)

$container.Controls.Add((New-Separator))

# Change key
$changeKey = New-MenuItem -text "Change key..." -onClick { Show-ChangeKeyDialog; $popup.Hide() }
$container.Controls.Add($changeKey.Panel)

# Pause / Resume (toggle check via Right label)
$pauseItem = New-MenuItem -text "Pause" -right ""
$pauseItem.Panel.Tag = "pause"
$container.Controls.Add($pauseItem.Panel)
$togglePauseClick = {
    $script:paused = -not $script:paused
    if ($script:paused) {
        $pauseItem.Label.Text = "Resume"
        $pauseItem.Right.Text = "II"
        $trayIcon.Text = "Nothing Headphones - PAUSED"
    } else {
        $pauseItem.Label.Text = "Pause"
        $pauseItem.Right.Text = ""
        $trayIcon.Text = "Nothing Headphones - tap = '$($script:currentKey)'"
    }
    $popup.Hide()
}.GetNewClosure()
$pauseItem.Panel.Add_Click($togglePauseClick)
$pauseItem.Label.Add_Click($togglePauseClick)
$pauseItem.Right.Add_Click($togglePauseClick)

# Autostart toggle - right label shows checkmark when on
$autostartItem = New-MenuItem -text "Start with Windows" -right ""
$container.Controls.Add($autostartItem.Panel)
if (Is-AutostartEnabled) { $autostartItem.Right.Text = [char]0x2713 }
$toggleAutoClick = {
    $isOn = (Is-AutostartEnabled)
    if ($isOn) {
        Disable-Autostart | Out-Null
        $autostartItem.Right.Text = ""
        $trayIcon.ShowBalloonTip(1500, "Autostart disabled", "Will not start with Windows.", "Info")
    } else {
        if (Enable-Autostart) {
            $autostartItem.Right.Text = [char]0x2713
            $trayIcon.ShowBalloonTip(1500, "Autostart enabled", "Will start with Windows.", "Info")
        }
    }
    $popup.Hide()
}.GetNewClosure()
$autostartItem.Panel.Add_Click($toggleAutoClick)
$autostartItem.Label.Add_Click($toggleAutoClick)
$autostartItem.Right.Add_Click($toggleAutoClick)

$container.Controls.Add((New-Separator))

# Exit
$exitItem = New-MenuItem -text "Exit" -danger $true -onClick {
    $popup.Hide()
    $trayIcon.Visible = $false
    Stop-Capture
    [System.Windows.Forms.Application]::Exit()
}
$container.Controls.Add($exitItem.Panel)

# Sizing / rounded corners (resize after content laid out)
$popup.Add_Shown({
    $popup.Height = $container.PreferredSize.Height + $popup.Padding.Vertical + 4
    Set-WindowRoundedDark -form $popup -radius 12
})

# Hide when clicking outside
$popup.Add_Deactivate({ $popup.Hide() })

# ---- Styled Change-Key dialog ---------------------------------------------
function Show-ChangeKeyDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = "None"
    $f.StartPosition   = "CenterScreen"
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.BackColor       = $Theme.BgPanel
    $f.Size            = New-Object System.Drawing.Size(380, 190)
    $f.Padding         = New-Object System.Windows.Forms.Padding(20)

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = "Change Key"
    $hdr.Font = New-Object System.Drawing.Font($FontFamily, 13, [System.Drawing.FontStyle]::Bold)
    $hdr.ForeColor = $Theme.TextPrimary
    $hdr.AutoSize = $true
    $hdr.Location = New-Object System.Drawing.Point(20, 18)
    $f.Controls.Add($hdr)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Examples:  F13, A, Ctrl+Shift+F13, Alt+M, Win+P"
    $hint.Font = $FontMuted
    $hint.ForeColor = $Theme.TextMuted
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(20, 46)
    $f.Controls.Add($hint)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font = New-Object System.Drawing.Font($FontFamily, 11)
    $tb.BorderStyle = "FixedSingle"
    $tb.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65)
    $tb.ForeColor = $Theme.TextPrimary
    $tb.Text = $script:currentKey
    $tb.Location = New-Object System.Drawing.Point(20, 78)
    $tb.Width = 340
    $tb.Height = 30
    $f.Controls.Add($tb)

    function New-StyledButton {
        param([string]$text, [System.Drawing.Color]$bg, [System.Drawing.Color]$fg, [int]$x, [scriptblock]$onClick)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Font = $FontReg
        $b.FlatStyle = "Flat"
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $bg
        $b.ForeColor = $fg
        $b.Size = New-Object System.Drawing.Size(90, 32)
        $b.Location = New-Object System.Drawing.Point($x, 130)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $bRef = $b
        $bg2 = $bg
        $b.Add_MouseEnter({ $bRef.BackColor = [System.Drawing.Color]::FromArgb([Math]::Min(255, $bg2.R + 25), [Math]::Min(255, $bg2.G + 25), [Math]::Min(255, $bg2.B + 25)) }.GetNewClosure())
        $b.Add_MouseLeave({ $bRef.BackColor = $bg2 }.GetNewClosure())
        if ($onClick) { $b.Add_Click($onClick) }
        return $b
    }

    $okClick = {
        $new = $tb.Text.Trim()
        try {
            $codes = Parse-Key $new
            $script:currentKey = $new
            $script:keyCodes   = $codes
            $keyInfo.Label.Text = "Key: $new"
            $trayIcon.Text = "Nothing Headphones - tap = '$new'"
            Save-Config
            $trayIcon.ShowBalloonTip(1500, "Key updated", "Headphone tap now sends '$new' (saved).", "Info")
            $f.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Invalid key '$new': $_", "Nothing Headphones") | Out-Null
        }
    }.GetNewClosure()

    $ok = New-StyledButton -text "Save" -bg $Theme.Accent -fg $Theme.AccentText -x 175 -onClick $okClick
    $cancel = New-StyledButton -text "Cancel" -bg ([System.Drawing.Color]::FromArgb(70,70,75)) -fg $Theme.TextPrimary -x 270 -onClick { $f.Close() }
    $f.Controls.Add($ok); $f.Controls.Add($cancel)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $f.Add_Shown({ Set-WindowRoundedDark -form $f -radius 14; $tb.Focus() })
    $f.ShowDialog() | Out-Null
}

# ---- Tray icon -------------------------------------------------------------
# Draw a simple white headphones glyph (transparent background) so the tray
# icon is instantly recognizable instead of a generic app icon.
function New-HeadphonesIcon {
    $sz = 64
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $white = [System.Drawing.Color]::White

    $bandPen = New-Object System.Drawing.Pen($white, 6.5)
    $bandPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $bandPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($bandPen, 17, 13, 30, 34, 180, 180)

    $cupPen = New-Object System.Drawing.Pen($white, 16)
    $cupPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $cupPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($cupPen, 17, 30, 17, 47)
    $g.DrawLine($cupPen, 47, 30, 47, 47)

    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
try   { $trayIcon.Icon = New-HeadphonesIcon }
catch { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
$trayIcon.Visible = $true
$trayIcon.Text    = "Nothing Headphones - tap = '$($script:currentKey)'"

# On any click (left or right), show our custom popup near the cursor.
$trayIcon.Add_MouseUp({
    param($sender, $e)
    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
    $x = $cursor.X - $popup.Width + 20
    $y = $cursor.Y - $popup.Height - 4
    if ($x + $popup.Width  -gt $screen.Right)  { $x = $screen.Right  - $popup.Width  - 8 }
    if ($y + $popup.Height -gt $screen.Bottom) { $y = $screen.Bottom - $popup.Height - 8 }
    if ($x -lt $screen.Left) { $x = $screen.Left + 8 }
    if ($y -lt $screen.Top)  { $y = $screen.Top  + 8 }
    $popup.Location = New-Object System.Drawing.Point($x, $y)
    $popup.Show()
    $popup.Activate()
})
$trayIcon.Add_DoubleClick({ Show-ChangeKeyDialog })

# ---- Polling timer ---------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    if (-not $script:reader) { return }
    while (-not $script:reader.EndOfStream) {
        $line = $script:reader.ReadLine()
        if ($null -eq $line) { break }
        $hex = $line.ToLower() -replace '[:\s]', ''
        if (-not $hex) { continue }
        if ($hex -match '41542b425652413d3[01]') {
            if (-not $script:paused) { Tap-Combo $script:keyCodes }
        }
    }
})

# ---- Boot up ---------------------------------------------------------------
# Upgrade any old tray.bat-based autostart entry to the direct command.
Repair-Autostart
Start-Capture
$ifInfo.Label.Text = "Interface: $($script:Interface)"
$trayIcon.ShowBalloonTip(2500,
    "Nothing Headphones detector",
    "Running. Tap headphone = '$($script:currentKey)'. Click the tray icon for options.",
    "Info")

$timer.Start()
[System.Windows.Forms.Application]::Run()

$timer.Stop()
Stop-Capture
