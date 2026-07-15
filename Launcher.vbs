Option Explicit

Dim shell, fileSystem, installRoot, appPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
installRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
appPath = fileSystem.BuildPath(installRoot, "src\CodexUsageTray.ps1")
command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Chr(34) & appPath & Chr(34) & " -HiddenLaunch"
shell.Run command, 0, False
