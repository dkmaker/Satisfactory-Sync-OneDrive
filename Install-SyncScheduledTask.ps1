#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs a scheduled task to run Satisfactory blueprint sync every 10 minutes
.DESCRIPTION
    Creates a Windows scheduled task that runs the sync script every 10 minutes,
    whether the user is logged in or not, using PowerShell 7 with hidden window
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceScriptPath = (Join-Path $PSScriptRoot "Sync-SatisfactoryBlueprints.ps1"),

    [Parameter()]
    [string]$InstallPath = "$env:OneDrive\Documents\Satisfactory\Sync",

    [Parameter()]
    [string]$TaskName = "SatisfactoryBlueprintSync",

    [Parameter()]
    [int]$IntervalMinutes = 10,

    [Parameter()]
    [switch]$Force
)

# Verify running as administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Please run PowerShell as Administrator and try again."
    exit 1
}

# Verify PowerShell 7 is installed
$pwsh7Path = "C:\Program Files\PowerShell\7\pwsh.exe"
if (!(Test-Path $pwsh7Path)) {
    Write-Error "PowerShell 7 is not installed at expected location: $pwsh7Path"
    Write-Host "Please install PowerShell 7 from: https://github.com/PowerShell/PowerShell/releases"
    exit 1
}

# Verify source sync script exists
if (!(Test-Path $SourceScriptPath)) {
    Write-Error "Source sync script not found at: $SourceScriptPath"
    exit 1
}

# Create installation directory if it doesn't exist
Write-Host "Setting up installation directory..." -ForegroundColor Yellow
if (!(Test-Path $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    Write-Host "Created installation directory: $InstallPath" -ForegroundColor Green
}

# Copy script to installation directory
$ScriptFileName = "Sync-SatisfactoryBlueprints.ps1"
$ScriptPath = Join-Path $InstallPath $ScriptFileName

Write-Host "Copying sync script to OneDrive..." -ForegroundColor Yellow
Copy-Item -Path $SourceScriptPath -Destination $ScriptPath -Force
Write-Host "Script copied to: $ScriptPath" -ForegroundColor Green

# Set the OneDrive folder to be available offline (pinned)
Write-Host "Configuring OneDrive offline availability..." -ForegroundColor Yellow
$satisfactoryFolder = Split-Path $InstallPath -Parent
try {
    # Check if already pinned
    $item = Get-Item $satisfactoryFolder -Force -ErrorAction Stop
    $isPinned = $item.Attributes -band [System.IO.FileAttributes]::Pinned

    if (-not $isPinned) {
        # Pin the Satisfactory folder and all subfolders
        $result = & attrib +P "$satisfactoryFolder" /S /D 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully pinned folder for offline availability: $satisfactoryFolder" -ForegroundColor Green
        }
        else {
            Write-Warning "Could not pin OneDrive folder. You may need to manually set it to 'Always keep on this device'"
            Write-Warning "Error: $result"
        }
    }
    else {
        Write-Host "Folder already pinned for offline availability" -ForegroundColor Green
    }
}
catch {
    Write-Warning "Error checking/setting OneDrive availability: $_"
}

Write-Host ""
Write-Host "Installing Satisfactory Blueprint Sync Scheduled Task" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Task Name: $TaskName"
Write-Host "Script Path: $ScriptPath"
Write-Host "Install Path: $InstallPath"
Write-Host "Interval: Every $IntervalMinutes minutes"
Write-Host "PowerShell 7: $pwsh7Path"
Write-Host ""

# Check if task already exists
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($existingTask) {
    if (!$Force) {
        $response = Read-Host "Task '$TaskName' already exists. Do you want to replace it? (Y/N)"
        if ($response -ne 'Y' -and $response -ne 'y') {
            Write-Host "Installation cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    Write-Host "Removing existing task..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Create the scheduled task
try {
    # Define the action (what the task will do)
    $action = New-ScheduledTaskAction `
        -Execute $pwsh7Path `
        -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # Define the triggers (when the task will run)
    # 1. Daily trigger (without repetition initially)
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At "00:00:00"

    # 2. Logon trigger - runs when user logs in
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Create triggers array
    $triggers = @($dailyTrigger, $logonTrigger)

    # Define the principal (who runs the task and how)
    # Using S4U prevents window popups but disables manual "Run now"
    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType S4U `
        -RunLevel Highest

    # Define settings (matching your XML configuration)
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    # Create the task
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $triggers `
        -Principal $principal `
        -Settings $settings `
        -Description "Synchronizes Satisfactory blueprints to OneDrive every $IntervalMinutes minutes"

    # Register the task
    Register-ScheduledTask `
        -TaskName $TaskName `
        -InputObject $task `
        -Force | Out-Null

    Write-Host "Task registered. Configuring repetition..." -ForegroundColor Yellow

    # Now modify the triggers to add repetition (this is the key step!)
    $registeredTask = Get-ScheduledTask -TaskName $TaskName

    # Configure repetition for the daily trigger (first trigger, index 0)
    $registeredTask.Triggers[0].Repetition.Duration = "P1D"     # Repeat for 1 day
    $registeredTask.Triggers[0].Repetition.Interval = "PT$($IntervalMinutes)M"  # Every X minutes
    $registeredTask.Triggers[0].Repetition.StopAtDurationEnd = $false

    # Update the task with the modified triggers
    Set-ScheduledTask -InputObject $registeredTask | Out-Null

    Write-Host "`nScheduled task installed successfully!" -ForegroundColor Green

    # Display task information
    Write-Host "`nTask Details:" -ForegroundColor Cyan
    $registeredTask = Get-ScheduledTask -TaskName $TaskName
    Write-Host "  State: $($registeredTask.State)"
    Write-Host "  Path: $($registeredTask.TaskPath)"
    Write-Host "  Next Run Time: $(($registeredTask | Get-ScheduledTaskInfo).NextRunTime)"

    # Test run option
    Write-Host "`nWould you like to test the task now? (Y/N): " -NoNewline
    $testResponse = Read-Host
    if ($testResponse -eq 'Y' -or $testResponse -eq 'y') {
        Write-Host "Starting test run..." -ForegroundColor Yellow
        Start-ScheduledTask -TaskName $TaskName

        Start-Sleep -Seconds 3

        $taskInfo = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
        Write-Host "Last Run Time: $($taskInfo.LastRunTime)"
        Write-Host "Last Task Result: 0x$($taskInfo.LastTaskResult.ToString('X8'))"

        if ($taskInfo.LastTaskResult -eq 0) {
            Write-Host "Test run completed successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "Test run may have encountered issues. Check the logs." -ForegroundColor Yellow
        }
    }

    Write-Host "`nInstallation complete!" -ForegroundColor Green
    Write-Host "Script installed to: $ScriptPath"
    Write-Host "The sync task will run every $IntervalMinutes minutes in the background."
    Write-Host "Logs will be saved to: `$env:OneDrive\Documents\Satisfactory\logs"

    # Provide management commands
    Write-Host "`nUseful commands:" -ForegroundColor Cyan
    Write-Host "  View task status:    Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
    Write-Host "  Run task manually:   Start-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  Disable task:        Disable-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  Enable task:         Enable-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  Remove task:         Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
    Write-Host "  Run script directly: pwsh.exe -ExecutionPolicy Bypass -File `"$ScriptPath`""
}
catch {
    Write-Error "Failed to create scheduled task: $_"
    exit 1
}