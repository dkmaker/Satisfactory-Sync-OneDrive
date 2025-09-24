#Requires -Version 7.0
<#
.SYNOPSIS
    Bidirectional sync of Satisfactory blueprints with OneDrive, version history, and conflict resolution
.DESCRIPTION
    This script provides bidirectional synchronization of blueprints between local Satisfactory
    folder and OneDrive, with version history tracking, conflict resolution, and automatic backups
#>

[CmdletBinding()]
param(
    [ValidateSet('Bidirectional', 'LocalToCloud', 'CloudToLocal')]
    [string]$SyncMode = 'Bidirectional',

    [int]$MaxVersionHistory = 10,

    [switch]$SkipOneDrivePinning
)

# Configuration
$script:Config = @{
    SourcePath = "$env:LocalAppData\FactoryGame\Saved\SaveGames\blueprints"
    OneDriveBase = "$env:OneDrive\Documents\Satisfactory"
    BlueprintsPath = "$env:OneDrive\Documents\Satisfactory\blueprints"
    BackupPath = "$env:OneDrive\Documents\Satisfactory\blueprints_backup"
    MetadataPath = "$env:OneDrive\Documents\Satisfactory\metadata.json"
    LogPath = "$env:OneDrive\Documents\Satisfactory\logs"
    DeviceId = $env:COMPUTERNAME
    SyncMode = $SyncMode
    MaxVersionHistory = $MaxVersionHistory
}

# Initialize logging
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Header')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logFile = Join-Path $script:Config.LogPath "sync_$(Get-Date -Format 'yyyyMMdd').log"

    # Ensure log directory exists
    if (!(Test-Path $script:Config.LogPath)) {
        New-Item -Path $script:Config.LogPath -ItemType Directory -Force | Out-Null
    }

    # Format log entry based on level
    $logEntry = if ($Level -eq 'Header') {
        $Message
    } else {
        "[$timestamp] [$Level] $Message"
    }

    Add-Content -Path $logFile -Value $logEntry -Force

    # Also write to console with color
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error $Message }
        'Header' { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message }
    }
}

# Rotate old log files (remove files older than 30 days)
function Rotate-Logs {
    try {
        if (Test-Path $script:Config.LogPath) {
            $cutoffDate = (Get-Date).AddDays(-30)
            $oldLogs = Get-ChildItem -Path $script:Config.LogPath -Filter "sync_*.log" |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }

            foreach ($oldLog in $oldLogs) {
                Remove-Item -Path $oldLog.FullName -Force
                Write-Log "Removed old log file: $($oldLog.Name)"
            }

            if ($oldLogs.Count -gt 0) {
                Write-Log "Rotated $($oldLogs.Count) old log file(s)"
            }
        }
    }
    catch {
        Write-Log "Error rotating logs: $_" -Level Warning
    }
}

# Load or initialize metadata
function Get-Metadata {
    if (Test-Path $script:Config.MetadataPath) {
        try {
            $content = Get-Content -Path $script:Config.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
            return $content
        }
        catch {
            Write-Log "Error loading metadata: $_" -Level Error
            return Initialize-Metadata
        }
    }
    else {
        return Initialize-Metadata
    }
}

# Initialize new metadata structure
function Initialize-Metadata {
    $metadata = @{
        version = "1.0"
        lastUpdated = (Get-Date -Format 'o')
        devices = @{}
        globalFiles = @{}
    }

    # Initialize current device
    $metadata.devices[$script:Config.DeviceId] = @{
        lastSync = (Get-Date -Format 'o')
        files = @{}
    }

    return $metadata
}

# Ensure OneDrive folder is available offline
function Ensure-OneDriveAvailability {
    if ($SkipOneDrivePinning) {
        Write-Log "Skipping OneDrive pinning (SkipOneDrivePinning flag set)"
        return
    }

    $folderPath = $script:Config.OneDriveBase

    try {
        # Check if folder exists
        if (!(Test-Path $folderPath)) {
            New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
            Write-Log "Created OneDrive folder: $folderPath"
        }

        # Check if already pinned (has the P attribute)
        $item = Get-Item $folderPath -Force -ErrorAction Stop
        $isPinned = $item.Attributes -band [System.IO.FileAttributes]::Pinned

        if (-not $isPinned) {
            Write-Log "Pinning OneDrive folder for offline availability: $folderPath"
            # Pin the folder and all subfolders/files
            $result = & attrib +P "$folderPath" /S /D 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully pinned OneDrive folder"
            }
            else {
                Write-Log "Warning: Could not pin OneDrive folder. Error: $result" -Level Warning
            }
        }
        else {
            Write-Log "OneDrive folder already pinned for offline availability"
        }
    }
    catch {
        Write-Log "Error checking/setting OneDrive availability: $_" -Level Warning
    }
}

# Save metadata
function Save-Metadata {
    param($Metadata)

    try {
        # Ensure directory exists
        $metadataDir = Split-Path $script:Config.MetadataPath -Parent
        if (!(Test-Path $metadataDir)) {
            New-Item -Path $metadataDir -ItemType Directory -Force | Out-Null
        }

        $Metadata.lastUpdated = (Get-Date -Format 'o')
        $json = $Metadata | ConvertTo-Json -Depth 10
        Set-Content -Path $script:Config.MetadataPath -Value $json -Force
        Write-Log "Metadata saved successfully"
    }
    catch {
        Write-Log "Error saving metadata: $_" -Level Error
        throw
    }
}

# Get file hash for comparison
function Get-FileHashString {
    param([string]$FilePath)

    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return $hash.Hash
    }
    catch {
        Write-Log "Error hashing file $FilePath : $_" -Level Warning
        return $null
    }
}

# Unified backup function for deletions and overwrites
function Backup-FileVersion {
    param(
        [string]$SourcePath,
        [string]$RelativePath,
        [string]$BackupReason = "unknown"
    )

    if (!(Test-Path $SourcePath)) {
        Write-Log "Cannot backup non-existent file: $SourcePath" -Level Warning
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $saveFolder = Split-Path $RelativePath -Parent
    $fileName = Split-Path $RelativePath -Leaf

    $backupFolder = Join-Path $script:Config.BackupPath $timestamp
    if ($saveFolder) {
        $backupFolder = Join-Path $backupFolder $saveFolder
    }

    # Create backup directory structure
    if (!(Test-Path $backupFolder)) {
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }

    $destPath = Join-Path $backupFolder $fileName

    try {
        # Copy with preserved attributes including timestamps
        $sourceItem = Get-Item $SourcePath
        Copy-Item -Path $SourcePath -Destination $destPath -Force

        # Preserve timestamps
        $destItem = Get-Item $destPath
        $destItem.CreationTime = $sourceItem.CreationTime
        $destItem.LastWriteTime = $sourceItem.LastWriteTime
        $destItem.LastAccessTime = $sourceItem.LastAccessTime

        Write-Log "Backed up file ($BackupReason): $RelativePath to $destPath"

        # Return relative backup path for metadata
        return Join-Path "blueprints_backup" (Join-Path $timestamp $RelativePath)
    }
    catch {
        Write-Log "Error backing up file: $_" -Level Error
        return $null
    }
}

# Add version to history array
function Add-ToVersionHistory {
    param(
        [hashtable]$FileEntry,
        [hashtable]$VersionInfo
    )

    if (!$FileEntry.ContainsKey('versions')) {
        $FileEntry.versions = @()
    }

    # Add new version
    $FileEntry.versions += $VersionInfo

    # Trim to max history
    if ($FileEntry.versions.Count -gt $script:Config.MaxVersionHistory) {
        $FileEntry.versions = $FileEntry.versions | Select-Object -Last $script:Config.MaxVersionHistory
    }
}

# Create version info object
function Get-FileVersionInfo {
    param(
        [string]$FilePath,
        [string]$Hash,
        [string]$Action = "sync",
        [string]$BackupPath = $null
    )

    $fileInfo = Get-Item $FilePath -ErrorAction SilentlyContinue

    return @{
        hash = $Hash
        lastModified = if ($fileInfo) { $fileInfo.LastWriteTime.ToString('o') } else { (Get-Date).ToString('o') }
        size = if ($fileInfo) { $fileInfo.Length } else { 0 }
        deviceId = $script:Config.DeviceId
        action = $Action
        backupPath = $BackupPath
        timestamp = (Get-Date -Format 'o')
    }
}

# Compare file versions and determine sync direction
function Compare-FileVersions {
    param(
        [string]$LocalPath,
        [string]$OneDrivePath,
        [string]$LocalHash,
        [string]$OneDriveHash
    )

    # If hashes are the same, no sync needed
    if ($LocalHash -eq $OneDriveHash) {
        return @{ Direction = 'None'; Reason = 'Files are identical' }
    }

    # Get file info
    $localInfo = Get-Item $LocalPath -ErrorAction SilentlyContinue
    $oneDriveInfo = Get-Item $OneDrivePath -ErrorAction SilentlyContinue

    # Handle missing files
    if (!$localInfo -and $oneDriveInfo) {
        return @{ Direction = 'CloudToLocal'; Reason = 'File only exists in OneDrive' }
    }
    if ($localInfo -and !$oneDriveInfo) {
        return @{ Direction = 'LocalToCloud'; Reason = 'File only exists locally' }
    }
    if (!$localInfo -and !$oneDriveInfo) {
        return @{ Direction = 'None'; Reason = 'File missing from both locations' }
    }

    # Both files exist but have different hashes - use newest
    if ($localInfo.LastWriteTime -gt $oneDriveInfo.LastWriteTime) {
        return @{ Direction = 'LocalToCloud'; Reason = "Local file is newer ($($localInfo.LastWriteTime) vs $($oneDriveInfo.LastWriteTime))" }
    }
    elseif ($oneDriveInfo.LastWriteTime -gt $localInfo.LastWriteTime) {
        return @{ Direction = 'CloudToLocal'; Reason = "OneDrive file is newer ($($oneDriveInfo.LastWriteTime) vs $($localInfo.LastWriteTime))" }
    }
    else {
        # Same timestamp but different content - prefer OneDrive for consistency
        return @{ Direction = 'CloudToLocal'; Reason = 'Files have same timestamp but different content, preferring OneDrive' }
    }
}

# Main sync function
function Sync-Blueprints {
    # Write session header
    Write-Log "" -Level Header
    Write-Log "========================================================================================================" -Level Header
    Write-Log "NEW SYNC SESSION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Header
    Write-Log "========================================================================================================" -Level Header
    Write-Log "Device: $($script:Config.DeviceId)" -Level Header
    Write-Log "Sync Mode: $($script:Config.SyncMode)" -Level Header
    Write-Log "Max Version History: $($script:Config.MaxVersionHistory)" -Level Header
    Write-Log "Skip OneDrive Pinning: $($SkipOneDrivePinning)" -Level Header
    Write-Log "Script Path: $($MyInvocation.PSCommandPath)" -Level Header
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)" -Level Header
    Write-Log "--------------------------------------------------------------------------------------------------------" -Level Header
    Write-Log "" -Level Header

    # Rotate old logs
    Rotate-Logs

    Write-Log "Starting blueprint sync for device: $($script:Config.DeviceId)" -Level Info

    # Ensure OneDrive is available
    Ensure-OneDriveAvailability

    # Ensure source path exists for local operations
    if ($script:Config.SyncMode -ne 'CloudToLocal') {
        if (!(Test-Path $script:Config.SourcePath)) {
            Write-Log "Source path does not exist: $($script:Config.SourcePath)" -Level Warning
            if ($script:Config.SyncMode -eq 'LocalToCloud') {
                return
            }
            # For bidirectional, create the path
            New-Item -Path $script:Config.SourcePath -ItemType Directory -Force | Out-Null
            Write-Log "Created source path: $($script:Config.SourcePath)"
        }
    }

    # Ensure destination paths exist
    @($script:Config.BlueprintsPath, $script:Config.BackupPath) | ForEach-Object {
        if (!(Test-Path $_)) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
            Write-Log "Created directory: $_"
        }
    }

    # Load metadata
    $metadata = Get-Metadata

    # Ensure globalFiles exists
    if (!$metadata.ContainsKey('globalFiles')) {
        $metadata.globalFiles = @{}
    }

    # Ensure device exists in metadata
    if (!$metadata.devices.ContainsKey($script:Config.DeviceId)) {
        $metadata.devices[$script:Config.DeviceId] = @{
            lastSync = (Get-Date -Format 'o')
            files = @{}
        }
    }

    $deviceData = $metadata.devices[$script:Config.DeviceId]
    $localFiles = @{}
    $oneDriveFiles = @{}
    $syncedCount = 0
    $deletedCount = 0
    $pulledCount = 0

    # STEP 1: Scan local files (if not CloudToLocal mode)
    if ($script:Config.SyncMode -ne 'CloudToLocal') {
        $saveGameFolders = Get-ChildItem -Path $script:Config.SourcePath -Directory -ErrorAction SilentlyContinue

        foreach ($saveFolder in $saveGameFolders) {
            $saveName = $saveFolder.Name
            Write-Log "Scanning local save game: $saveName"

            # Get all blueprint files (.sbp and .sbpcfg)
            $blueprintFiles = @()
            $blueprintFiles += Get-ChildItem -Path $saveFolder.FullName -Filter "*.sbp" -File -ErrorAction SilentlyContinue
            $blueprintFiles += Get-ChildItem -Path $saveFolder.FullName -Filter "*.sbpcfg" -File -ErrorAction SilentlyContinue

            foreach ($file in $blueprintFiles) {
                $relativePath = Join-Path $saveName $file.Name
                $fileHash = Get-FileHashString -FilePath $file.FullName

                $localFiles[$relativePath] = @{
                    fullPath = $file.FullName
                    hash = $fileHash
                    lastModified = $file.LastWriteTime.ToString('o')
                    size = $file.Length
                }
            }
        }
    }

    # STEP 2: Scan OneDrive files (if not LocalToCloud mode)
    if ($script:Config.SyncMode -ne 'LocalToCloud') {
        if (Test-Path $script:Config.BlueprintsPath) {
            $oneDriveSaveFolders = Get-ChildItem -Path $script:Config.BlueprintsPath -Directory -ErrorAction SilentlyContinue

            foreach ($saveFolder in $oneDriveSaveFolders) {
                $saveName = $saveFolder.Name
                Write-Log "Scanning OneDrive save game: $saveName"

                # Get all blueprint files (.sbp and .sbpcfg)
                $blueprintFiles = @()
                $blueprintFiles += Get-ChildItem -Path $saveFolder.FullName -Filter "*.sbp" -File -ErrorAction SilentlyContinue
                $blueprintFiles += Get-ChildItem -Path $saveFolder.FullName -Filter "*.sbpcfg" -File -ErrorAction SilentlyContinue

                foreach ($file in $blueprintFiles) {
                    $relativePath = Join-Path $saveName $file.Name
                    $fileHash = Get-FileHashString -FilePath $file.FullName

                    $oneDriveFiles[$relativePath] = @{
                        fullPath = $file.FullName
                        hash = $fileHash
                        lastModified = $file.LastWriteTime.ToString('o')
                        size = $file.Length
                    }
                }
            }
        }
    }

    # STEP 3: Process all files for bidirectional sync
    $allFiles = @{}

    # Add all local files
    foreach ($key in $localFiles.Keys) {
        $allFiles[$key] = @{ Local = $localFiles[$key]; OneDrive = $null }
    }

    # Add/update with OneDrive files
    foreach ($key in $oneDriveFiles.Keys) {
        if ($allFiles.ContainsKey($key)) {
            $allFiles[$key].OneDrive = $oneDriveFiles[$key]
        }
        else {
            $allFiles[$key] = @{ Local = $null; OneDrive = $oneDriveFiles[$key] }
        }
    }

    # STEP 4: Sync each file
    foreach ($relativePath in $allFiles.Keys) {
        $fileInfo = $allFiles[$relativePath]
        $saveName = Split-Path $relativePath -Parent

        # Prepare device file entry
        if (!$deviceData.files.ContainsKey($relativePath)) {
            $deviceData.files[$relativePath] = @{
                current = @{}
                versions = @()
            }
        }

        $deviceFileEntry = $deviceData.files[$relativePath]

        # Determine sync action
        if ($fileInfo.Local -and $fileInfo.OneDrive) {
            # File exists in both locations
            $localPath = $fileInfo.Local.fullPath
            $oneDrivePath = $fileInfo.OneDrive.fullPath

            $comparison = Compare-FileVersions `
                -LocalPath $localPath `
                -OneDrivePath $oneDrivePath `
                -LocalHash $fileInfo.Local.hash `
                -OneDriveHash $fileInfo.OneDrive.hash

            Write-Log "File $relativePath : $($comparison.Reason)"

            switch ($comparison.Direction) {
                'LocalToCloud' {
                    if ($script:Config.SyncMode -ne 'CloudToLocal') {
                        # Backup OneDrive version before overwrite
                        $backupPath = Backup-FileVersion `
                            -SourcePath $oneDrivePath `
                            -RelativePath $relativePath `
                            -BackupReason "overwrite"

                        # Add to version history
                        if ($backupPath) {
                            $versionInfo = Get-FileVersionInfo `
                                -FilePath $oneDrivePath `
                                -Hash $fileInfo.OneDrive.hash `
                                -Action "overwrite" `
                                -BackupPath $backupPath
                            Add-ToVersionHistory -FileEntry $deviceFileEntry -VersionInfo $versionInfo
                        }

                        # Copy local to OneDrive preserving timestamps
                        try {
                            $sourceItem = Get-Item $localPath
                            Copy-Item -Path $localPath -Destination $oneDrivePath -Force

                            # Preserve timestamps
                            $destItem = Get-Item $oneDrivePath
                            $destItem.CreationTime = $sourceItem.CreationTime
                            $destItem.LastWriteTime = $sourceItem.LastWriteTime
                            $destItem.LastAccessTime = $sourceItem.LastAccessTime

                            Write-Log "Pushed to OneDrive: $relativePath"
                            $syncedCount++
                        }
                        catch {
                            Write-Log "Error pushing $relativePath to OneDrive: $_" -Level Error
                        }
                    }
                }
                'CloudToLocal' {
                    if ($script:Config.SyncMode -ne 'LocalToCloud') {
                        # Ensure local directory exists
                        $localDir = Join-Path $script:Config.SourcePath $saveName
                        if (!(Test-Path $localDir)) {
                            New-Item -Path $localDir -ItemType Directory -Force | Out-Null
                        }

                        $localPath = Join-Path $script:Config.SourcePath $relativePath

                        # Backup local version before overwrite
                        if (Test-Path $localPath) {
                            $backupPath = Backup-FileVersion `
                                -SourcePath $localPath `
                                -RelativePath $relativePath `
                                -BackupReason "overwrite"

                            # Add to version history
                            if ($backupPath) {
                                $versionInfo = Get-FileVersionInfo `
                                    -FilePath $localPath `
                                    -Hash $fileInfo.Local.hash `
                                    -Action "overwrite" `
                                    -BackupPath $backupPath
                                Add-ToVersionHistory -FileEntry $deviceFileEntry -VersionInfo $versionInfo
                            }
                        }

                        # Copy OneDrive to local preserving timestamps
                        try {
                            $sourceItem = Get-Item $oneDrivePath
                            Copy-Item -Path $oneDrivePath -Destination $localPath -Force

                            # Preserve timestamps
                            $destItem = Get-Item $localPath
                            $destItem.CreationTime = $sourceItem.CreationTime
                            $destItem.LastWriteTime = $sourceItem.LastWriteTime
                            $destItem.LastAccessTime = $sourceItem.LastAccessTime

                            Write-Log "Pulled from OneDrive: $relativePath"
                            $pulledCount++
                        }
                        catch {
                            Write-Log "Error pulling $relativePath from OneDrive: $_" -Level Error
                        }
                    }
                }
            }

            # Update current version info
            $currentHash = if ($comparison.Direction -eq 'CloudToLocal') { $fileInfo.OneDrive.hash } else { $fileInfo.Local.hash }
            $deviceFileEntry.current = @{
                hash = $currentHash
                lastModified = (Get-Date).ToString('o')
                size = if ($fileInfo.Local) { $fileInfo.Local.size } else { $fileInfo.OneDrive.size }
            }
        }
        elseif ($fileInfo.Local -and !$fileInfo.OneDrive) {
            # File only exists locally
            if ($script:Config.SyncMode -ne 'CloudToLocal') {
                # Create OneDrive directory if needed
                $oneDriveDir = Join-Path $script:Config.BlueprintsPath $saveName
                if (!(Test-Path $oneDriveDir)) {
                    New-Item -Path $oneDriveDir -ItemType Directory -Force | Out-Null
                }

                $oneDrivePath = Join-Path $script:Config.BlueprintsPath $relativePath
                $localPath = $fileInfo.Local.fullPath

                try {
                    $sourceItem = Get-Item $localPath
                    Copy-Item -Path $localPath -Destination $oneDrivePath -Force

                    # Preserve timestamps
                    $destItem = Get-Item $oneDrivePath
                    $destItem.CreationTime = $sourceItem.CreationTime
                    $destItem.LastWriteTime = $sourceItem.LastWriteTime
                    $destItem.LastAccessTime = $sourceItem.LastAccessTime

                    Write-Log "New file pushed to OneDrive: $relativePath"
                    $syncedCount++
                }
                catch {
                    Write-Log "Error pushing new file $relativePath : $_" -Level Error
                }

                # Update current version info
                $deviceFileEntry.current = @{
                    hash = $fileInfo.Local.hash
                    lastModified = $fileInfo.Local.lastModified
                    size = $fileInfo.Local.size
                }
            }
        }
        elseif (!$fileInfo.Local -and $fileInfo.OneDrive) {
            # File only exists in OneDrive
            if ($script:Config.SyncMode -ne 'LocalToCloud') {
                # Create local directory if needed
                $localDir = Join-Path $script:Config.SourcePath $saveName
                if (!(Test-Path $localDir)) {
                    New-Item -Path $localDir -ItemType Directory -Force | Out-Null
                }

                $localPath = Join-Path $script:Config.SourcePath $relativePath
                $oneDrivePath = $fileInfo.OneDrive.fullPath

                try {
                    $sourceItem = Get-Item $oneDrivePath
                    Copy-Item -Path $oneDrivePath -Destination $localPath -Force

                    # Preserve timestamps
                    $destItem = Get-Item $localPath
                    $destItem.CreationTime = $sourceItem.CreationTime
                    $destItem.LastWriteTime = $sourceItem.LastWriteTime
                    $destItem.LastAccessTime = $sourceItem.LastAccessTime

                    Write-Log "New file pulled from OneDrive: $relativePath"
                    $pulledCount++
                }
                catch {
                    Write-Log "Error pulling new file $relativePath : $_" -Level Error
                }

                # Update current version info
                $deviceFileEntry.current = @{
                    hash = $fileInfo.OneDrive.hash
                    lastModified = $fileInfo.OneDrive.lastModified
                    size = $fileInfo.OneDrive.size
                }
            }
        }

        # Update global file tracking
        if ($deviceFileEntry.current.hash) {
            $metadata.globalFiles[$relativePath] = @{
                latestHash = $deviceFileEntry.current.hash
                latestModified = $deviceFileEntry.current.lastModified
                latestDevice = $script:Config.DeviceId
            }
        }
    }

    # STEP 5: Check for deletions (files in metadata but not in current scan)
    $filesToDelete = @()
    foreach ($trackedFile in $deviceData.files.Keys) {
        $stillExists = $false

        # Check if file still exists locally or in OneDrive based on sync mode
        if ($script:Config.SyncMode -eq 'LocalToCloud' -or $script:Config.SyncMode -eq 'Bidirectional') {
            if ($localFiles.ContainsKey($trackedFile)) {
                $stillExists = $true
            }
        }
        if ($script:Config.SyncMode -eq 'CloudToLocal' -or $script:Config.SyncMode -eq 'Bidirectional') {
            if ($oneDriveFiles.ContainsKey($trackedFile)) {
                $stillExists = $true
            }
        }

        if (!$stillExists) {
            $filesToDelete += $trackedFile
        }
    }

    # Process deletions
    foreach ($deletedFile in $filesToDelete) {
        Write-Log "File deleted: $deletedFile"

        # Check if file exists in OneDrive for backup
        $oneDrivePath = Join-Path $script:Config.BlueprintsPath $deletedFile
        if (Test-Path $oneDrivePath) {
            # Check if any other device still has this file
            $otherDevicesHaveFile = $false
            foreach ($deviceId in $metadata.devices.Keys) {
                if ($deviceId -ne $script:Config.DeviceId) {
                    $otherDevice = $metadata.devices[$deviceId]
                    if ($otherDevice.files.ContainsKey($deletedFile)) {
                        # Check if the other device's version is current (not deleted)
                        if ($otherDevice.files[$deletedFile].current.hash) {
                            $otherDevicesHaveFile = $true
                            break
                        }
                    }
                }
            }

            if (!$otherDevicesHaveFile) {
                # No other device has this file, safe to backup and remove
                $backupPath = Backup-FileVersion `
                    -SourcePath $oneDrivePath `
                    -RelativePath $deletedFile `
                    -BackupReason "deletion"

                # Add deletion to version history
                if ($backupPath -and $deviceData.files.ContainsKey($deletedFile)) {
                    $fileEntry = $deviceData.files[$deletedFile]
                    $versionInfo = Get-FileVersionInfo `
                        -FilePath $oneDrivePath `
                        -Hash (Get-FileHashString -FilePath $oneDrivePath) `
                        -Action "deletion" `
                        -BackupPath $backupPath
                    Add-ToVersionHistory -FileEntry $fileEntry -VersionInfo $versionInfo

                    # Clear current version to indicate deletion
                    $fileEntry.current = @{}
                }

                # Remove the file from OneDrive
                Remove-Item -Path $oneDrivePath -Force
                $deletedCount++

                # Also handle the corresponding .sbpcfg or .sbp file
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($deletedFile)
                $extension = [System.IO.Path]::GetExtension($deletedFile)
                $companionExt = if ($extension -eq '.sbp') { '.sbpcfg' } else { '.sbp' }
                $companionFile = Join-Path (Split-Path $deletedFile -Parent) "$baseName$companionExt"
                $companionPath = Join-Path $script:Config.BlueprintsPath $companionFile

                if (Test-Path $companionPath) {
                    Backup-FileVersion `
                        -SourcePath $companionPath `
                        -RelativePath $companionFile `
                        -BackupReason "deletion-companion"
                    Remove-Item -Path $companionPath -Force
                }

                # Remove from global files
                if ($metadata.globalFiles.ContainsKey($deletedFile)) {
                    $metadata.globalFiles.Remove($deletedFile)
                }
                if ($metadata.globalFiles.ContainsKey($companionFile)) {
                    $metadata.globalFiles.Remove($companionFile)
                }
            }
            else {
                Write-Log "File still exists on other devices, keeping in OneDrive: $deletedFile"
                # Just mark as deleted on this device
                if ($deviceData.files.ContainsKey($deletedFile)) {
                    $deviceData.files[$deletedFile].current = @{}
                }
            }
        }
        else {
            # File already removed from OneDrive, just update metadata
            if ($deviceData.files.ContainsKey($deletedFile)) {
                $deviceData.files[$deletedFile].current = @{}
            }
        }
    }

    # Update device metadata
    $deviceData.lastSync = (Get-Date -Format 'o')

    # Save metadata
    Save-Metadata -Metadata $metadata

    # Clean up empty save folders in both locations
    if ($script:Config.SyncMode -ne 'CloudToLocal') {
        $localSaveFolders = Get-ChildItem -Path $script:Config.SourcePath -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $localSaveFolders) {
            $files = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue
            if ($files.Count -eq 0) {
                Remove-Item -Path $folder.FullName -Force
                Write-Log "Removed empty local folder: $($folder.Name)"
            }
        }
    }

    if ($script:Config.SyncMode -ne 'LocalToCloud') {
        $oneDriveSaveFolders = Get-ChildItem -Path $script:Config.BlueprintsPath -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $oneDriveSaveFolders) {
            $files = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue
            if ($files.Count -eq 0) {
                Remove-Item -Path $folder.FullName -Force
                Write-Log "Removed empty OneDrive folder: $($folder.Name)"
            }
        }
    }

    Write-Log "Sync completed. Pushed: $syncedCount, Pulled: $pulledCount, Deleted: $deletedCount" -Level Info

    # Write session footer
    Write-Log "" -Level Header
    Write-Log "========================================================================================================" -Level Header
    Write-Log "END OF SYNC SESSION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Header
    Write-Log "Summary: Pushed: $syncedCount | Pulled: $pulledCount | Deleted: $deletedCount" -Level Header
    Write-Log "========================================================================================================" -Level Header
    Write-Log "" -Level Header
}

# Main execution
try {
    Sync-Blueprints
}
catch {
    Write-Log "Critical error during sync: $_" -Level Error
    Write-Log "" -Level Header
    Write-Log "========================================================================================================" -Level Header
    Write-Log "SYNC SESSION FAILED - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Header
    Write-Log "Error: $_" -Level Header
    Write-Log "========================================================================================================" -Level Header
    exit 1
}