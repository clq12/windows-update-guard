' WinUpdateGuard launcher - start the main script as administrator (no console window)
Option Explicit

Dim fso, sh, baseDir, ps1, args, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Shell.Application")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = baseDir & "\WinUpdateGuard.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "WinUpdateGuard.ps1 was not found." & vbCrLf & vbCrLf & _
           "Keep this launcher and the script in the same folder.", 16, "WinUpdateGuard"
    WScript.Quit 1
End If

args = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

On Error Resume Next
sh.ShellExecute "powershell.exe", args, baseDir, "runas", 0
rc = Err.Number
On Error GoTo 0

If rc <> 0 Then
    MsgBox "Administrator permission was not granted." & vbCrLf & vbCrLf & _
           "This tool needs admin rights to change update services and policies.", 48, "WinUpdateGuard"
End If
