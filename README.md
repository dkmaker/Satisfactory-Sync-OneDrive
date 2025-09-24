# Satisfactory Blueprint Sync for OneDrive

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue.svg)](https://www.microsoft.com/windows)
[![Satisfactory](https://img.shields.io/badge/Satisfactory-1.1-orange.svg)](https://www.satisfactorygame.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Automated bidirectional synchronization of Satisfactory blueprints with OneDrive, featuring version history, conflict resolution, and multi-device support.

🎮 **Game:** [Satisfactory](https://www.satisfactorygame.com/) by [Coffee Stain Studios](https://www.coffeestainstudios.com/games/satisfactory)

## Problem Solved

Satisfactory blueprints are **not** synchronized to Steam Cloud. This solution:
- **Bidirectional sync** between local Satisfactory folder and OneDrive
- **Version history** with up to 10 versions per file stored in backups
- **Conflict resolution** by keeping the newest file based on timestamps
- **Multi-device support** with file-centric tracking and global file state
- **Enhanced deletion handling** with immediate OneDrive cleanup and cross-device propagation
- **Smart backup** for all conflicts, overwrites, and deletions with comprehensive coverage
- **Companion file coordination** - .sbp and .sbpcfg files handled together
- **Automatic OneDrive pinning** to ensure files are always available offline

## Features

- **Bidirectional Sync Modes**:
  - `Bidirectional` (default): Syncs in both directions
  - `LocalToCloud`: Only pushes local changes to OneDrive
  - `CloudToLocal`: Only pulls OneDrive changes to local

- **Version History**: Tracks up to 10 versions of each file with:
  - Hash, timestamp, size, and device information
  - Backup location for recovery
  - Action type (overwrite, deletion, conflict)

- **Intelligent Conflict Resolution**:
  - Compares file timestamps when both changed
  - Backs up the losing version before overwrite
  - Preserves all file timestamps during copy operations
  - Clear conflict logging with backup tracking

- **OneDrive Integration**:
  - Automatically pins folder for offline availability
  - Checks pin status before setting to minimize overhead
  - Optional flag to skip pinning if needed

- **Comprehensive Logging**: Detailed sync operations log for troubleshooting

## 🚀 Quick Start

### Prerequisites

- Windows 10/11
- Windows PowerShell 5.1 (built into Windows 10/11)
- OneDrive configured and running
- Administrator privileges (for scheduled task installation)
- [Satisfactory](https://store.steampowered.com/app/526870/Satisfactory/) installed

### Installation

1. **Clone or download this repository**
   ```powershell
   git clone https://github.com/dkmaker/Satisfactory-Sync-OneDrive.git
   cd Satisfactory-Sync-OneDrive
   ```

2. **Run the installer as Administrator**
   ```powershell
   # Open Windows PowerShell as Administrator
   # Set execution policy for current process (if needed)
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

   # Run the installer
   .\Install-SyncScheduledTask.ps1
   ```

3. **That's it!** The sync will run automatically:
   - At user logon
   - Every 10 minutes throughout the day
   - Logs available at `%OneDrive%\Documents\Satisfactory\logs`

## File Structure

```
OneDrive\Documents\Satisfactory\
├── metadata.json                   # Sync state and device tracking
├── blueprints\                     # Synced blueprints
│   └── [Save Game Name]\           # Folder per save game
│       ├── Blueprint1.sbp          # Blueprint data
│       └── Blueprint1.sbpcfg       # Blueprint config
├── blueprints_backup\               # Deleted file backups
│   └── [yyyyMMddHHmmss]\           # Timestamp folders
│       └── [Save Game Name]\       # Original structure preserved
└── logs\                           # Sync logs
    └── sync_[yyyyMMdd].log        # Daily log files
```

## How It Works

1. **Source Locations**:
   - Local: `%LocalAppData%\FactoryGame\Saved\SaveGames\blueprints\`
   - Cloud: `%OneDrive%\Documents\Satisfactory\blueprints\`

2. **Bidirectional Sync Process**:
   - Scans both local and OneDrive folders
   - Compares files using SHA256 hashes
   - For conflicts (both changed): keeps newest based on LastWriteTime
   - Backs up older versions before overwriting
   - Preserves original file timestamps during all copy operations

3. **Version History**:
   - Maintains up to 10 versions per file (configurable)
   - Each version includes hash, timestamp, device, and backup location
   - Older versions automatically pruned (FIFO)

4. **Enhanced Deletion Handling**:
   - Detects deletions by comparing device's previous file list vs current scan
   - Immediately removes deleted files from OneDrive with backup
   - Handles companion files (.sbp/.sbpcfg) together during deletion
   - Cross-device deletion propagation ensures consistency
   - Supports file re-creation with same name (fresh lifecycle)
   - All backups stored in `blueprints_backup/[timestamp]/` folders

## Metadata Structure

```json
{
  "version": "2.0",
  "lastUpdated": "2025-01-24T10:00:00Z",
  "files": {
    "First Factory/Blueprint1.sbp": {
      "fileId": "uuid-1234-5678-9abc",
      "globalStatus": "active",
      "deletedBy": null,
      "deletedTimestamp": null,
      "lastKnownHash": "SHA256...",
      "devices": {
        "DESKTOP-ABC123": {
          "status": "active",
          "hash": "SHA256...",
          "lastModified": "2025-01-24T10:00:00Z",
          "lastSeen": "2025-01-24T10:00:00Z"
        }
      },
      "versions": [
        {
          "hash": "SHA256...",
          "timestamp": "2025-01-24T10:00:00Z",
          "device": "DESKTOP-ABC123",
          "action": "create"
        }
      ]
    }
  },
  "devices": {
    "DESKTOP-ABC123": {
      "lastSync": "2025-01-24T10:00:00Z",
      "lastKnownFiles": {
        "First Factory/Blueprint1.sbp": "SHA256..."
      }
    }
  }
}
```

## Management Commands

```powershell
# View task status
Get-ScheduledTask -TaskName 'SatisfactoryBlueprintSync' | Get-ScheduledTaskInfo

# Run sync manually
Start-ScheduledTask -TaskName 'SatisfactoryBlueprintSync'

# Disable sync temporarily
Disable-ScheduledTask -TaskName 'SatisfactoryBlueprintSync'

# Re-enable sync
Enable-ScheduledTask -TaskName 'SatisfactoryBlueprintSync'

# Uninstall scheduled task
Unregister-ScheduledTask -TaskName 'SatisfactoryBlueprintSync' -Confirm:$false
```

## Manual Sync

To run the sync manually without the scheduled task:
```powershell
# Default bidirectional sync
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.ps1"

# Push only (local to cloud)
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.ps1" -SyncMode LocalToCloud

# Pull only (cloud to local)
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.ps1" -SyncMode CloudToLocal

# Skip OneDrive pinning
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.ps1" -SkipOneDrivePinning

# Custom version history limit (default is 10)
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.ps1" -MaxVersionHistory 20

# Or use the VBScript wrapper for silent execution
wscript.exe "C:\Scripts\SatisfactorySync\Sync-SatisfactoryBlueprints.vbs"
```

## Troubleshooting

### Sync not running
1. Check task status: `Get-ScheduledTask -TaskName 'SatisfactoryBlueprintSync'`
2. Review logs at: `$env:OneDrive\Documents\Satisfactory\logs\`
3. Verify Windows PowerShell is available: `powershell.exe -Command "Get-Host"`

### Files not syncing
1. Check source folder exists: `%LocalAppData%\FactoryGame\Saved\SaveGames\blueprints\`
2. Ensure OneDrive is running and syncing
3. Review metadata.json for device entries
4. Check file permissions on both source and destination

### Deleted files reappearing
- This is prevented by the metadata tracking system
- Check metadata.json to ensure your device is properly registered
- Files are moved to blueprints_backup with timestamps, not deleted

## 🎮 Game Information

- **Satisfactory** is a first-person open-world factory building game by Coffee Stain Studios
- [Official Website](https://www.satisfactorygame.com/)
- [Steam Store Page](https://store.steampowered.com/app/526870/Satisfactory/)
- [Epic Games Store](https://store.epicgames.com/en-US/p/satisfactory)
- [Satisfactory Wiki](https://satisfactory.wiki.gg/)

## 📝 Notes

- Blueprints require the **Mark 1 Blueprint Designer** to be unlocked in-game
- Each blueprint consists of two files: `.sbp` (data) and `.sbpcfg` (config)
- Save game folders are created automatically as needed
- Empty folders are cleaned up automatically
- The scheduled task uses Interactive logon with VBScript wrapper for completely silent execution

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Coffee Stain Studios](https://www.coffeestainstudios.com/) for creating Satisfactory
- The Satisfactory community for blueprint sharing inspiration
- Microsoft for PowerShell and OneDrive integration

## ⚠️ Disclaimer

This tool is not affiliated with, endorsed by, or connected to Coffee Stain Studios or Satisfactory. Satisfactory is a trademark of Coffee Stain Studios AB.