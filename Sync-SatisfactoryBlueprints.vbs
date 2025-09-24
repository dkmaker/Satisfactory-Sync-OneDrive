' Satisfactory Blueprint Sync - VBScript Wrapper
' This script launches the PowerShell sync script with no visible window
' Used by Windows Task Scheduler for silent background execution

' Create objects
Dim shell, fso
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Get the directory where this VBScript is located
Dim scriptDir, psScriptPath
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScriptPath = fso.BuildPath(scriptDir, "Sync-SatisfactoryBlueprints.ps1")

' Find Windows PowerShell executable
Dim pwshPath, pwshFound
pwshPath = ""
pwshFound = False

' Try Windows PowerShell locations first
Dim ps5Paths(1)
ps5Paths(0) = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
ps5Paths(1) = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

For i = 0 To UBound(ps5Paths)
    If fso.FileExists(ps5Paths(i)) Then
        pwshPath = ps5Paths(i)
        pwshFound = True
        Exit For
    End If
Next

' Final fallback - try PATH
If Not pwshFound Then
    On Error Resume Next
    Dim testResult
    testResult = shell.Run("powershell.exe -Command ""exit 0""", 0, True)
    If Err.Number = 0 And testResult = 0 Then
        pwshPath = "powershell.exe"
        pwshFound = True
    End If
    On Error GoTo 0
End If

' If no PowerShell found, show error and exit
If Not pwshFound Then
    MsgBox "Windows PowerShell is not installed on this system." & vbCrLf & vbCrLf & _
           "Windows PowerShell 5.1 should be available by default on Windows 10/11.", _
           vbCritical, "Satisfactory Blueprint Sync - PowerShell Not Found"
    WScript.Quit 1
End If

' Build the PowerShell command with full paths and optimal parameters
Dim psCommand
psCommand = """" & pwshPath & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & psScriptPath & """"

' Execute PowerShell with window hidden (parameter 0 = completely hidden)
' Parameter 0 ensures no console window appears at all
shell.Run psCommand, 0

' Clean up
Set shell = Nothing
Set fso = Nothing