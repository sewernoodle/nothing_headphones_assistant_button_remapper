' Nothing Headphones (1) detector - flash-free launcher.
'
' powershell.exe is a console app: launching it directly briefly shows a
' console window before -WindowStyle Hidden can hide it. wscript.exe has no
' console of its own, and .Run with window style 0 starts PowerShell hidden
' from the very first instant - so there is no flash at all.
Option Explicit
Dim sh, fso, here, ps1
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\tray.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
