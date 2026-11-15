Option Explicit

' Launches slideshow-guard.ps1 with no visible console window.
' Window style 0 = hidden; the third argument False means "do not wait".

Dim shell, fso, here, ps1, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = here & "\slideshow-guard.ps1"

If Not fso.FileExists(ps1) Then
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
shell.Run cmd, 0, False
