# Personal USB Backup Helper (Windows 10/11)

A lightweight, transparent, user-scoped PowerShell + `robocopy` utility that runs in your logged-in Windows user session, watches for inserted removable USB drives (`DriveType = 2`), and backs up their contents to a timestamped folder on your Desktop (`Desktop\USB_Backups\<label>_<timestamp>`).

## Safety & Design Principles

- **Removable drives only (`DriveType = 2`)**: Explicitly filters `Win32_LogicalDisk` for `DriveType = 2` AND verifies `[System.IO.DriveInfo]::DriveType -eq 'Removable'` and `IsReady`, plus explicitly blocks `$env:SystemDrive`. Internal drives (`DriveType = 3`), network drives, optical drives, and empty card readers are ignored.
- **Never executes anything from USB**: Only inspects volume metadata and copies files with built-in `robocopy.exe` (with `/XJ` to skip junctions/symlinks).
- **Hidden & system files excluded by default**: Skips hidden/system files (`/XA:SH`) and hidden/system folders (including `System Volume Information` and `$RECYCLE.BIN`) unless `"includeHiddenSystem": true` is explicitly set in `config.json` (or `-IncludeHiddenSystem` is passed manually).
- **Current-user session only (no admin, no SYSTEM)**: Registers a `Limited` / `Interactive` Scheduled Task triggered `AtLogOn` for the current user only. No UAC prompt, no machine-wide service.
- **Handles unplug & replug**: Tracks connected drives by drive letter and volume serial number, listens to `Win32_VolumeChangeEvent` (plus polling fallback), and forgets disconnected drives so reinserting triggers a fresh timestamped backup.
- **Full logging**: Logs watcher lifecycle, detections, removals, copied files, and any errors under `Desktop\USB_Backups\logs\`.

---

## Quick Start (One-Command Deployment)

```powershell
git clone <your-repo-url> personal-usb-backup
cd personal-usb-backup
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```
Just simply do this to get this thing running 
cd whatever_folder
powershell -ExecutionPolicy Bypass -File .\setup.ps1
powershell -ExecutionPolicy Bypass -File d:\pendrive_problem\uninstall.ps1

That's it — `setup.ps1`:
1. Creates `Desktop\USB_Backups\logs\` (automatically resolving OneDrive-redirected or standard Desktop paths via `[Environment]::GetFolderPath('Desktop')`).
2. Registers the user-scoped Scheduled Task `PersonalUsbBackupHelper` to run at login for the current user only.
3. Starts the background helper immediately so you don't have to log out and back in.

---

## Testing Manually Before Installing

Before registering the scheduled task, you can test `usb-backup.ps1` directly in your terminal:

1. **Dry run (no files copied, no backup folders created on Desktop):**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\usb-backup.ps1 -Once -DryRun -Console
   ```
   This uses `robocopy /L` to simulate what removable drives and files would be copied and prints output directly to the console (writing only a dry-run log under `Desktop\USB_Backups\logs\`).

2. **Single-pass live test to an isolated folder:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\usb-backup.ps1 -Once -Console -BackupRoot "$env:TEMP\usb_test_backups"
   ```
   Insert a test USB stick and run the command above to verify only that USB stick is copied, hidden/system files are skipped, and logs are created.

3. **Interactive watcher test (test unplug/replug in foreground):**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\usb-backup.ps1 -Console -BackupRoot "$env:TEMP\usb_test_backups"
   ```
   Watch the console output as you insert, unplug, and reinsert a USB drive. Press `Ctrl+C` to stop when finished.

4. **Test including hidden/system files:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\usb-backup.ps1 -Once -DryRun -IncludeHiddenSystem -Console
   ```

5. **Run the automated test suite (no physical USB drive required):**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
   ```

---

## How `setup.ps1` Creates the Scheduled Task

`setup.ps1` uses PowerShell's built-in `ScheduledTasks` cmdlets (`Register-ScheduledTask`) rather than `schtasks.exe` because:

- **`-Trigger (New-ScheduledTaskTrigger -AtLogOn -User $currentUser)`**: Scopes the logon trigger strictly to the current user (omitting `-User` requires Administrator rights).
- **`-Principal (New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited)`**: Runs in the logged-in user's interactive session with standard privileges (no elevation, no `SYSTEM`).
- **`-ExecutionTimeLimit (New-TimeSpan -Seconds 0)`**: Disables Task Scheduler's default 72-hour kill timeout so the background watcher stays running across multi-day sessions. (`schtasks.exe /Create /SC ONLOGON` does not expose this option on the CLI without importing raw XML.)
- **`-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`**: Prevents laptops from suspending backups when unplugged from AC power.
- **`-MultipleInstances IgnoreNew`**: Prevents duplicate background watchers if triggered again.

*(If you ever inspect the equivalent via `schtasks.exe`, it corresponds to `schtasks /Create /TN PersonalUsbBackupHelper /SC ONLOGON /RL LIMITED /TR "..."` — except `Register-ScheduledTask` additionally removes the 72-hour timeout and battery restrictions cleanly.)*

---

## How to Verify It Is Running

1. **Check the Scheduled Task state and last run result:**
   ```powershell
   Get-ScheduledTask -TaskName PersonalUsbBackupHelper | Select-Object TaskName, State
   Get-ScheduledTaskInfo -TaskName PersonalUsbBackupHelper
   ```
   `State` should show `Running`.

2. **Check the running PowerShell background process:**
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
     Where-Object { $_.CommandLine -like '*usb-backup.ps1*' } |
     Select-Object ProcessId, CommandLine
   ```

3. **Inspect the watcher log:**
   ```powershell
   $desktop = [Environment]::GetFolderPath('Desktop')
   Get-Content (Join-Path $desktop 'USB_Backups\logs\usb-backup.log') -Tail 20
   ```

---

## Stopping, Disabling, or Uninstalling

Scheduled task name: **`PersonalUsbBackupHelper`**

- **Stop the helper right now (stays enabled for next login):**
  ```powershell
  Stop-ScheduledTask -TaskName PersonalUsbBackupHelper
  ```

- **Disable auto-start at login (and stop it):**
  ```powershell
  Stop-ScheduledTask -TaskName PersonalUsbBackupHelper
  Disable-ScheduledTask -TaskName PersonalUsbBackupHelper
  ```

- **Re-enable and start again:**
  ```powershell
  Enable-ScheduledTask -TaskName PersonalUsbBackupHelper
  Start-ScheduledTask -TaskName PersonalUsbBackupHelper
  ```

- **Uninstall the scheduled task completely (leaves all backups & logs intact):**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  ```

---

## Configuration (`config.json`)

Edit `config.json` (or create a gitignored `config.local.json` with only the keys you want to override):

| Key | Default | Description |
| --- | --- | --- |
| `taskName` | `"PersonalUsbBackupHelper"` | Windows Scheduled Task name. |
| `backupRootPath` | `""` | Custom backup folder path (supports `%VAR%`). Empty = `Desktop\USB_Backups`. |
| `includeHiddenSystem` | `false` | Set `true` to also copy hidden/system files and directories. |
| `backupExistingOnStartup` | `true` | Back up removable drives already inserted at login/startup. |
| `pollIntervalSeconds` | `3` | Polling / event wait interval in seconds. |
| `settleDelayMs` | `1500` | Wait time after USB insertion before copying, for volume mount readiness. |
| `robocopyRetries` | `2` | `robocopy /R` retry count on locked/unreadable files. |
| `robocopyWaitSeconds` | `1` | `robocopy /W` wait seconds between retries. |
| `excludeDirectories` | `[]` | Extra directory names or paths passed to `robocopy /XD`. |
| `timestampFormat` | `"yyyy-MM-dd_HH-mm-ss"` | Timestamp format used in `<label>_<timestamp>` folder names. |

## Backup Folder Layout

```text
Desktop\USB_Backups\
├── SANDISK_2026-11-12_08-15-00\
│   └── <copied files and folders from the USB drive>
└── logs\
    ├── usb-backup.log
    └── SANDISK_2026-11-12_08-15-00.log
```

