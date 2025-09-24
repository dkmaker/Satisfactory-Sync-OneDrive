#Requires -Version 5.1
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

            if ($oldLogs -and (@($oldLogs).Count -gt 0)) {
                Write-Log "Rotated $(@($oldLogs).Count) old log file(s)"
            }
        }
    }
    catch {
        Write-Log "Error rotating logs: $_" -Level Warning
    }
}

# Convert PSCustomObject to hashtable recursively
function ConvertTo-Hashtable {
    param([PSObject]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [PSCustomObject]) {
        $hashtable = @{}
        $InputObject.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [PSCustomObject]) {
                $hashtable[$_.Name] = ConvertTo-Hashtable -InputObject $_.Value
            }
            elseif ($_.Value -is [Array]) {
                $hashtable[$_.Name] = @()
                foreach ($item in $_.Value) {
                    if ($item -is [PSCustomObject]) {
                        $hashtable[$_.Name] += ConvertTo-Hashtable -InputObject $item
                    }
                    else {
                        $hashtable[$_.Name] += $item
                    }
                }
            }
            else {
                $hashtable[$_.Name] = $_.Value
            }
        }
        return $hashtable
    }
    elseif ($InputObject -is [Array]) {
        $array = @()
        foreach ($item in $InputObject) {
            if ($item -is [PSCustomObject]) {
                $array += ConvertTo-Hashtable -InputObject $item
            }
            else {
                $array += $item
            }
        }
        return $array
    }
    else {
        return $InputObject
    }
}

# Load or initialize metadata
function Get-Metadata {
    if (Test-Path $script:Config.MetadataPath) {
        try {
            $jsonContent = Get-Content -Path $script:Config.MetadataPath -Raw | ConvertFrom-Json
            # Convert PSCustomObject to hashtable for PowerShell 5.1 compatibility
            $hashtable = ConvertTo-Hashtable -InputObject $jsonContent

            # Check if this is V2.0 metadata structure
            if (!$hashtable.ContainsKey('version') -or $hashtable.version -ne "2.0") {
                Write-Log "Detected old metadata format. Initializing new V2.0 structure (old metadata will be backed up)" -Level Warning

                # Backup old metadata
                $backupPath = $script:Config.MetadataPath -replace '\.json$', "_backup_$(Get-Date -Format 'yyyyMMddHHmmss').json"
                Copy-Item -Path $script:Config.MetadataPath -Destination $backupPath -Force
                Write-Log "Old metadata backed up to: $backupPath" -Level Info

                # Return fresh V2.0 structure
                return Initialize-Metadata
            }

            return $hashtable
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

# Initialize new file-centric metadata structure V2.0
function Initialize-Metadata {
    $metadata = @{
        version = "2.0"
        lastUpdated = (Get-Date -Format 'o')
        files = @{}
        devices = @{}
    }

    # Initialize current device (simplified - only stores sync info)
    $metadata.devices[$script:Config.DeviceId] = @{
        lastSync = (Get-Date -Format 'o')
        lastKnownFiles = @{} # Tracks what files this device had in previous sync
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

        # Check if we're actually in a OneDrive folder
        if ($folderPath -notlike "*\OneDrive*") {
            Write-Log "Warning: Path doesn't appear to be in OneDrive: $folderPath" -Level Warning
            return
        }

        Write-Log "Pinning OneDrive folder and ALL contents recursively for offline availability: $folderPath"

        # Pin ALL existing files and folders recursively using lowercase +p
        # Note: OneDrive Files On-Demand uses lowercase attributes: +p for pinned, +u for unpinned
        $result = & attrib +p "$folderPath\*" /S /D 2>&1

        if ($LASTEXITCODE -eq 0) {
            # Pin the root folder itself to ensure new files inherit the pinned state
            & attrib +p "$folderPath" 2>&1 | Out-Null
            Write-Log "Successfully pinned OneDrive folder recursively for complete offline availability: $folderPath"
        }
        else {
            Write-Log "Warning: Could not pin all OneDrive content. Trying alternative approach..." -Level Warning
            Write-Log "Error: $result" -Level Warning

            # Fallback 1: Try pinning root folder with recursive flag
            $fallbackResult = & attrib +p "$folderPath" /S /D 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully pinned OneDrive folder with fallback method"
            }
            else {
                Write-Log "Fallback method also failed. Trying individual subfolder approach..." -Level Warning

                # Fallback 2: Pin individual subfolders recursively
                $subFolders = @($script:Config.BlueprintsPath, $script:Config.BackupPath, $script:Config.LogPath)
                foreach ($subFolder in $subFolders) {
                    if (Test-Path $subFolder) {
                        # Pin all content in subfolder
                        & attrib +p "$subFolder\*" /S /D 2>$null
                        # Pin the subfolder itself
                        & attrib +p "$subFolder" 2>$null

                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Successfully pinned all content in subfolder: $subFolder"
                        }
                        else {
                            Write-Log "Could not fully pin subfolder: $subFolder" -Level Warning
                        }
                    }
                }
            }
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
        if (!(Test-Path $FilePath)) {
            Write-Log "Cannot hash non-existent file: $FilePath" -Level Warning
            return $null
        }

        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return $hash.Hash
    }
    catch {
        Write-Log "Error hashing file $FilePath : $_" -Level Warning
        return $null
    }
}

# Copy file with timestamp preservation
function Copy-FileWithTimestamps {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    try {
        $sourceItem = Get-Item $SourcePath
        Copy-Item -Path $SourcePath -Destination $DestinationPath -Force

        $destItem = Get-Item $DestinationPath
        $destItem.CreationTime = $sourceItem.CreationTime
        $destItem.LastWriteTime = $sourceItem.LastWriteTime
        $destItem.LastAccessTime = $sourceItem.LastAccessTime

        return $true
    }
    catch {
        Write-Log "Error copying file with timestamps: $_" -Level Error
        return $false
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

# Get or create file entry in file-centric metadata
function Get-FileEntry {
    param(
        [hashtable]$Metadata,
        [string]$RelativePath
    )

    if (!$Metadata.files.ContainsKey($RelativePath)) {
        $Metadata.files[$RelativePath] = @{
            fileId = [System.Guid]::NewGuid().ToString()
            globalStatus = "active"
            deletedBy = $null
            deletedTimestamp = $null
            lastKnownHash = $null
            devices = @{}
            versions = @()
        }
    }

    return $Metadata.files[$RelativePath]
}

# Update device status for a specific file
function Set-DeviceFileStatus {
    param(
        [hashtable]$FileEntry,
        [string]$DeviceId,
        [string]$Status,           # "active", "deleted", "never-had"
        [string]$Hash = $null,
        [string]$LastModified = $null
    )

    if (!$FileEntry.devices.ContainsKey($DeviceId)) {
        $FileEntry.devices[$DeviceId] = @{}
    }

    $FileEntry.devices[$DeviceId].status = $Status
    $FileEntry.devices[$DeviceId].lastSeen = (Get-Date -Format 'o')

    if ($Hash) {
        $FileEntry.devices[$DeviceId].hash = $Hash
        $FileEntry.lastKnownHash = $Hash
    }

    if ($LastModified) {
        $FileEntry.devices[$DeviceId].lastModified = $LastModified
    }
}

# Add version to file history
function Add-FileVersion {
    param(
        [hashtable]$FileEntry,
        [string]$Hash,
        [string]$Action,  # "create", "update", "delete"
        [string]$DeviceId
    )

    $versionInfo = @{
        hash = $Hash
        timestamp = (Get-Date -Format 'o')
        device = $DeviceId
        action = $Action
    }

    $FileEntry.versions += $versionInfo

    # Trim to max history
    if (@($FileEntry.versions).Count -gt $script:Config.MaxVersionHistory) {
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

    # Load metadata (V2.0 file-centric structure)
    $metadata = Get-Metadata

    # Ensure device exists in metadata
    if (!$metadata.devices.ContainsKey($script:Config.DeviceId)) {
        $metadata.devices[$script:Config.DeviceId] = @{
            lastSync = (Get-Date -Format 'o')
            lastKnownFiles = @{}
        }
    }

    $deviceInfo = $metadata.devices[$script:Config.DeviceId]

    # Ensure lastKnownFiles property exists (may be missing in older V2.0 metadata)
    if (!$deviceInfo.ContainsKey('lastKnownFiles')) {
        $deviceInfo.lastKnownFiles = @{}
    }

    $previousFiles = $deviceInfo.lastKnownFiles
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

                # Skip files with hash errors
                if ($null -eq $fileHash) {
                    Write-Log "Skipping file due to hash error: $relativePath" -Level Warning
                    continue
                }

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

                    # Skip files with hash errors
                    if ($null -eq $fileHash) {
                        Write-Log "Skipping OneDrive file due to hash error: $relativePath" -Level Warning
                        continue
                    }

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

    # STEP 3: Detect deletions by comparing previous vs current scan
    $currentFiles = @{}
    foreach ($key in $localFiles.Keys) {
        $currentFiles[$key] = $localFiles[$key].hash
    }

    # Find deleted files (existed before, missing now)
    $deletedFiles = @()
    foreach ($prevFile in $previousFiles.Keys) {
        if (!$currentFiles.ContainsKey($prevFile)) {
            $deletedFiles += $prevFile
            Write-Log "Detected deletion: $prevFile"
        }
    }

    # STEP 4: Process deleted files - mark as deleted and remove from OneDrive immediately
    $processedDeletions = @()  # Track all files deleted in this step (including companions)

    foreach ($deletedPath in $deletedFiles) {
        $fileEntry = Get-FileEntry -Metadata $metadata -RelativePath $deletedPath

        # Check if file exists in OneDrive and backup before deletion
        $oneDrivePath = Join-Path $script:Config.BlueprintsPath $deletedPath
        if (Test-Path $oneDrivePath) {
            Write-Log "File deleted locally, removing from OneDrive: $deletedPath"

            # Backup OneDrive version before deletion
            Backup-FileVersion -SourcePath $oneDrivePath -RelativePath $deletedPath -BackupReason "deletion" | Out-Null

            # Remove from OneDrive
            Remove-Item -Path $oneDrivePath -Force -ErrorAction SilentlyContinue

            # Handle companion file (.sbp <-> .sbpcfg)
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($deletedPath)
            $extension = [System.IO.Path]::GetExtension($deletedPath)
            $companionExt = if ($extension -eq '.sbp') { '.sbpcfg' } else { '.sbp' }
            $companionFile = Join-Path (Split-Path $deletedPath -Parent) "$baseName$companionExt"
            $companionPath = Join-Path $script:Config.BlueprintsPath $companionFile

            if (Test-Path $companionPath) {
                Write-Log "Also removing companion file: $companionFile"
                Backup-FileVersion -SourcePath $companionPath -RelativePath $companionFile -BackupReason "deletion-companion" | Out-Null
                Remove-Item -Path $companionPath -Force -ErrorAction SilentlyContinue

                # Mark companion as deleted too
                $companionEntry = Get-FileEntry -Metadata $metadata -RelativePath $companionFile
                $companionEntry.globalStatus = "deleted"
                $companionEntry.deletedBy = $script:Config.DeviceId
                $companionEntry.deletedTimestamp = (Get-Date -Format 'o')
                Set-DeviceFileStatus -FileEntry $companionEntry -DeviceId $script:Config.DeviceId -Status "deleted"

                # Get companion hash before it was deleted (from previous files if available)
                $companionHash = if ($previousFiles.ContainsKey($companionFile)) {
                    $previousFiles[$companionFile]
                } else {
                    "unknown"
                }
                Add-FileVersion -FileEntry $companionEntry -Hash $companionHash -Action "delete" -DeviceId $script:Config.DeviceId

                # Track companion as processed
                $processedDeletions += $companionFile
            }
        }

        # Mark file as globally deleted
        $fileEntry.globalStatus = "deleted"
        $fileEntry.deletedBy = $script:Config.DeviceId
        $fileEntry.deletedTimestamp = (Get-Date -Format 'o')

        # Update this device's status
        Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "deleted"

        # Add deletion to version history
        Add-FileVersion -FileEntry $fileEntry -Hash $previousFiles[$deletedPath] -Action "delete" -DeviceId $script:Config.DeviceId

        # Track this file as processed
        $processedDeletions += $deletedPath

        $deletedCount++
    }

    # STEP 5: Process all current files (local and OneDrive)
    $allCurrentFiles = @{}

    # Add local files
    foreach ($path in $localFiles.Keys) {
        $allCurrentFiles[$path] = @{
            Local = $localFiles[$path]
            OneDrive = $null
        }
    }

    # Add OneDrive files
    foreach ($path in $oneDriveFiles.Keys) {
        if ($allCurrentFiles.ContainsKey($path)) {
            $allCurrentFiles[$path].OneDrive = $oneDriveFiles[$path]
        } else {
            $allCurrentFiles[$path] = @{
                Local = $null
                OneDrive = $oneDriveFiles[$path]
            }
        }
    }

    # STEP 6: Process each file with file-centric logic
    foreach ($relativePath in $allCurrentFiles.Keys) {
        # Skip files that were deleted in this sync session
        if ($processedDeletions -contains $relativePath) {
            continue
        }

        $fileInfo = $allCurrentFiles[$relativePath]
        $saveName = Split-Path $relativePath -Parent

        # Get or create file entry in file-centric metadata
        $fileEntry = Get-FileEntry -Metadata $metadata -RelativePath $relativePath

        # Check if this is a new file with same name as a deleted file
        if ($fileEntry.globalStatus -eq "deleted") {
            # Check if this is actually a new file (different hash than last known)
            $isNewFile = $false

            if ($fileInfo.Local -and $fileInfo.Local.hash -ne $fileEntry.lastKnownHash) {
                $isNewFile = $true
            }
            elseif ($fileInfo.OneDrive -and $fileInfo.OneDrive.hash -ne $fileEntry.lastKnownHash) {
                $isNewFile = $true
            }

            if ($isNewFile) {
                Write-Log "New file created with same name as previously deleted file: $relativePath"
                # Reset to active status - this is a new file lifecycle
                $fileEntry.globalStatus = "active"
                $fileEntry.deletedBy = $null
                $fileEntry.deletedTimestamp = $null
                $fileEntry.fileId = [System.Guid]::NewGuid().ToString()  # New file ID for new lifecycle
            }
            else {
                # This is the same old deleted file, remove it
                if ($fileInfo.Local) {
                    Write-Log "Removing locally found file marked as deleted: $relativePath"
                    Remove-Item -Path $fileInfo.Local.fullPath -Force -ErrorAction SilentlyContinue
                }
                if ($fileInfo.OneDrive) {
                    Write-Log "Removing OneDrive file marked as deleted: $relativePath"
                    Backup-FileVersion -SourcePath $fileInfo.OneDrive.fullPath -RelativePath $relativePath -BackupReason "global_deletion"
                    Remove-Item -Path $fileInfo.OneDrive.fullPath -Force -ErrorAction SilentlyContinue
                }
                continue
            }
        }

        # Process file based on where it exists
        if ($fileInfo.Local -and $fileInfo.OneDrive) {
            # File exists in both locations - check if they're different
            if ($fileInfo.Local.hash -eq $fileInfo.OneDrive.hash) {
                Write-Log "File $relativePath : Files are identical"

                # Update device status to active
                Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.Local.hash -LastModified $fileInfo.Local.lastModified
            }
            else {
                # Files differ - determine which is newer
                $localTime = [DateTime]::Parse($fileInfo.Local.lastModified)
                $oneDriveTime = [DateTime]::Parse($fileInfo.OneDrive.lastModified)

                if ($localTime -gt $oneDriveTime) {
                    Write-Log "CONFLICT RESOLVED: Local file is newer, backing up OneDrive version: $relativePath" -Level Warning
                    # Backup OneDrive version (the "losing" file in conflict)
                    Backup-FileVersion -SourcePath $fileInfo.OneDrive.fullPath -RelativePath $relativePath -BackupReason "conflict_resolution" | Out-Null
                    # Push local to OneDrive
                    if (Copy-FileWithTimestamps -SourcePath $fileInfo.Local.fullPath -DestinationPath $fileInfo.OneDrive.fullPath) {
                        Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.Local.hash -LastModified $fileInfo.Local.lastModified
                        Add-FileVersion -FileEntry $fileEntry -Hash $fileInfo.Local.hash -Action "conflict_win" -DeviceId $script:Config.DeviceId
                        $syncedCount++
                    }
                }
                elseif ($oneDriveTime -gt $localTime) {
                    Write-Log "CONFLICT RESOLVED: OneDrive file is newer, backing up local version: $relativePath" -Level Warning
                    # Backup local version (the "losing" file in conflict)
                    Backup-FileVersion -SourcePath $fileInfo.Local.fullPath -RelativePath $relativePath -BackupReason "conflict_resolution" | Out-Null
                    # Pull OneDrive to local
                    if (Copy-FileWithTimestamps -SourcePath $fileInfo.OneDrive.fullPath -DestinationPath $fileInfo.Local.fullPath) {
                        Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.OneDrive.hash -LastModified $fileInfo.OneDrive.lastModified
                        Add-FileVersion -FileEntry $fileEntry -Hash $fileInfo.OneDrive.hash -Action "conflict_win" -DeviceId $script:Config.DeviceId
                        $pulledCount++
                    }
                }
                else {
                    # Same timestamp but different content - backup local, prefer OneDrive
                    Write-Log "CONFLICT RESOLVED: Same timestamp, different content. Backing up local, preferring OneDrive: $relativePath" -Level Warning
                    Backup-FileVersion -SourcePath $fileInfo.Local.fullPath -RelativePath $relativePath -BackupReason "timestamp_conflict" | Out-Null
                    if (Copy-FileWithTimestamps -SourcePath $fileInfo.OneDrive.fullPath -DestinationPath $fileInfo.Local.fullPath) {
                        Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.OneDrive.hash -LastModified $fileInfo.OneDrive.lastModified
                        Add-FileVersion -FileEntry $fileEntry -Hash $fileInfo.OneDrive.hash -Action "conflict_win" -DeviceId $script:Config.DeviceId
                        $pulledCount++
                    }
                }
            }
        }
        elseif ($fileInfo.Local -and !$fileInfo.OneDrive) {
            # File only exists locally - push to OneDrive (if not CloudToLocal mode)
            if ($script:Config.SyncMode -ne 'CloudToLocal') {
                Write-Log "New file pushed to OneDrive: $relativePath"
                $oneDriveDir = Join-Path $script:Config.BlueprintsPath $saveName
                if (!(Test-Path $oneDriveDir)) { New-Item -Path $oneDriveDir -ItemType Directory -Force | Out-Null }
                $oneDrivePath = Join-Path $oneDriveDir (Split-Path $relativePath -Leaf)

                # Check if file already exists and backup if needed
                if (Test-Path $oneDrivePath) {
                    Backup-FileVersion -SourcePath $oneDrivePath -RelativePath $relativePath -BackupReason "new_file_overwrite" | Out-Null
                }

                # Copy with timestamp preservation
                if (Copy-FileWithTimestamps -SourcePath $fileInfo.Local.fullPath -DestinationPath $oneDrivePath) {
                    Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.Local.hash -LastModified $fileInfo.Local.lastModified
                    Add-FileVersion -FileEntry $fileEntry -Hash $fileInfo.Local.hash -Action "create" -DeviceId $script:Config.DeviceId
                    $syncedCount++
                }
            }
        }
        elseif (!$fileInfo.Local -and $fileInfo.OneDrive) {
            # File only exists in OneDrive - pull to local (if not LocalToCloud mode)
            if ($script:Config.SyncMode -ne 'LocalToCloud') {
                Write-Log "New file pulled from OneDrive: $relativePath"
                $localDir = Join-Path $script:Config.SourcePath $saveName
                if (!(Test-Path $localDir)) { New-Item -Path $localDir -ItemType Directory -Force | Out-Null }
                $localPath = Join-Path $localDir (Split-Path $relativePath -Leaf)

                # Check if file already exists locally and backup if needed
                if (Test-Path $localPath) {
                    Backup-FileVersion -SourcePath $localPath -RelativePath $relativePath -BackupReason "new_file_overwrite" | Out-Null
                }

                # Copy with timestamp preservation
                if (Copy-FileWithTimestamps -SourcePath $fileInfo.OneDrive.fullPath -DestinationPath $localPath) {
                    Set-DeviceFileStatus -FileEntry $fileEntry -DeviceId $script:Config.DeviceId -Status "active" -Hash $fileInfo.OneDrive.hash -LastModified $fileInfo.OneDrive.lastModified
                    Add-FileVersion -FileEntry $fileEntry -Hash $fileInfo.OneDrive.hash -Action "create" -DeviceId $script:Config.DeviceId
                    $pulledCount++
                }
            }
        }
    }

    # STEP 7: Handle cross-device deletion propagation (only for files not processed in current session)
    foreach ($filePath in $metadata.files.Keys) {
        $fileEntry = $metadata.files[$filePath]

        # If file is globally deleted, ensure it's removed from all devices
        if ($fileEntry.globalStatus -eq "deleted") {
            # Skip files that were deleted in this sync session (already handled in STEP 4)
            if ($processedDeletions -contains $filePath) {
                continue
            }

            # Check if this device still has the file and remove it
            $localPath = Join-Path $script:Config.SourcePath $filePath
            $oneDrivePath = Join-Path $script:Config.BlueprintsPath $filePath

            if (Test-Path $localPath) {
                Write-Log "Removing locally found file marked as globally deleted: $filePath"
                Remove-Item -Path $localPath -Force -ErrorAction SilentlyContinue
            }

            if (Test-Path $oneDrivePath) {
                Write-Log "Removing OneDrive file marked as globally deleted by another device: $filePath"
                # Backup since this is from another device's deletion
                Backup-FileVersion -SourcePath $oneDrivePath -RelativePath $filePath -BackupReason "cross_device_deletion" | Out-Null
                Remove-Item -Path $oneDrivePath -Force -ErrorAction SilentlyContinue
                $deletedCount++
            }
        }
    }

    # STEP 8: Update device's lastKnownFiles for next sync comparison
    $deviceInfo.lastKnownFiles = @{}
    foreach ($path in $localFiles.Keys) {
        $deviceInfo.lastKnownFiles[$path] = $localFiles[$path].hash
    }

    # STEP 9: Update device sync timestamp
    $deviceInfo.lastSync = (Get-Date -Format 'o')

    # Save metadata with atomic operation
    try {
        Save-Metadata -Metadata $metadata
    }
    catch {
        Write-Log "CRITICAL: Failed to save metadata. Sync state may be inconsistent: $_" -Level Error
        throw "Metadata save failed - sync state compromised"
    }

    # Clean up empty save folders in both locations
    if ($script:Config.SyncMode -ne 'CloudToLocal') {
        $localSaveFolders = Get-ChildItem -Path $script:Config.SourcePath -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $localSaveFolders) {
            $files = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue
            if (@($files).Count -eq 0) {
                Remove-Item -Path $folder.FullName -Force
                Write-Log "Removed empty local folder: $($folder.Name)"
            }
        }
    }

    if ($script:Config.SyncMode -ne 'LocalToCloud') {
        if (Test-Path $script:Config.BlueprintsPath) {
            $oneDriveSaveFolders = Get-ChildItem -Path $script:Config.BlueprintsPath -Directory -ErrorAction SilentlyContinue
            foreach ($folder in $oneDriveSaveFolders) {
                $files = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue
                if (@($files).Count -eq 0) {
                    Remove-Item -Path $folder.FullName -Force
                    Write-Log "Removed empty OneDrive folder: $($folder.Name)"
                }
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