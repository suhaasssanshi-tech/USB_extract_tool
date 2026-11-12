<#
.SYNOPSIS
    Automated self-contained test suite for Personal USB Backup Helper.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$mainScript = Join-Path $repoRoot 'usb-backup.ps1'
$setupScript = Join-Path $repoRoot 'setup.ps1'
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'
$configFile = Join-Path $repoRoot 'config.json'

$passed = 0
$failed = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if ($Condition) {
        $script:passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )
    if ($Expected -eq $Actual) {
        $script:passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host "  [FAIL] $Message (Expected='$Expected', Actual='$Actual')" -ForegroundColor Red
    }
}

$tempWorkspace = Join-Path $env:TEMP "usb_backup_tests_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempWorkspace -Force | Out-Null
$testTaskName = "PersonalUsbBackupHelper_Test_$(Get-Random)"

try {
    Write-Host '1. Syntax and config validation'
    foreach ($scriptPath in @($mainScript, $setupScript, $uninstallScript)) {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 $errors.Count "Zero PowerShell parse errors in $(Split-Path $scriptPath -Leaf)"
    }

    $cfgJson = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $false ([bool]$cfgJson.includeHiddenSystem) 'config.json defaults includeHiddenSystem to false'
    Assert-Equal 'PersonalUsbBackupHelper' $cfgJson.taskName 'config.json sets documented taskName'

    # Dot-source main script helpers.
    . $mainScript

    Write-Host '2. Path resolution and label sanitization'
    $resolvedDefaultRoot = Resolve-BackupRootPath -ConfiguredPath '' -OverridePath ''
    $expectedDesktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($expectedDesktop)) {
        $expectedDesktop = Join-Path $env:USERPROFILE 'Desktop'
    }
    Assert-Equal (Join-Path $expectedDesktop 'USB_Backups') $resolvedDefaultRoot 'Resolves Desktop\USB_Backups dynamically'

    $expandedCustom = Resolve-BackupRootPath -ConfiguredPath '%TEMP%\CustomUsb' -OverridePath ''
    Assert-Equal (Join-Path $env:TEMP 'CustomUsb') $expandedCustom 'Expands environment variables in backupRootPath'

    Assert-Equal 'MY_USB_1' (Get-SafeVolumeLabel -VolumeName 'MY/USB:1*' -DriveId 'E:') 'Sanitizes invalid filename characters'
    Assert-Equal 'USB_E' (Get-SafeVolumeLabel -VolumeName '   ' -DriveId 'E:') 'Falls back to USB_<letter> when label is empty'
    Assert-Equal 'USB_CON' (Get-SafeVolumeLabel -VolumeName 'CON' -DriveId 'E:') 'Prefixes reserved Windows device names'

    $collisionDir = Join-Path $tempWorkspace 'collision'
    New-Item -ItemType Directory -Path $collisionDir -Force | Out-Null
    $fmt = 'yyyyMMdd_HHmmss'
    $name1 = Get-UniqueBackupFolderName -BackupRoot $collisionDir -SafeLabel 'TEST' -TimestampFormat $fmt
    New-Item -ItemType Directory -Path (Join-Path $collisionDir $name1) -Force | Out-Null
    $name2 = Get-UniqueBackupFolderName -BackupRoot $collisionDir -SafeLabel 'TEST' -TimestampFormat $fmt
    Assert-True ($name1 -ne $name2) "Generates unique folder name on collision ($name1 vs $name2)"

    Write-Host '3. Removable drive filtering (DriveType = 2 only)'
    $liveRemovable = @(Get-ReadyRemovableDrives)
    $liveRemovableIds = @($liveRemovable | ForEach-Object { $_.DeviceID })
    $systemDrive = $env:SystemDrive.ToUpperInvariant()
    Assert-True (-not ($liveRemovableIds -contains $systemDrive)) "System drive ($systemDrive) is never returned as removable"
    $fixedDisks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3')
    foreach ($fd in $fixedDisks) {
        Assert-True (-not ($liveRemovableIds -contains $fd.DeviceID.ToUpperInvariant())) "Fixed internal disk $($fd.DeviceID) is excluded"
    }

    # Verify Get-ReadyRemovableDrives ignores empty card readers (Size = null), SystemDrive, and DriveType != 2
    & {
        function Get-CimInstance {
            return @(
                [PSCustomObject]@{ DeviceID = $env:SystemDrive; DriveType = 2; VolumeName = 'FakeSys'; VolumeSerialNumber = '1'; FileSystem = 'NTFS'; Size = 1000 }
                [PSCustomObject]@{ DeviceID = 'Z:'; DriveType = 2; VolumeName = ''; VolumeSerialNumber = ''; FileSystem = ''; Size = $null }
                [PSCustomObject]@{ DeviceID = 'Y:'; DriveType = 3; VolumeName = 'Fixed'; VolumeSerialNumber = '2'; FileSystem = 'NTFS'; Size = 1000 }
            )
        }
        $filtered = @(Get-ReadyRemovableDrives)
        Assert-Equal 0 $filtered.Count 'Filters out DriveType!=2, SystemDrive, and unmounted/empty media (Size=null)'
    }

    Write-Host '4. Robocopy hidden/system exclusion, inclusion, and logging'
    $srcUsb = Join-Path $tempWorkspace 'fake_usb'
    New-Item -ItemType Directory -Path "$srcUsb\docs", "$srcUsb\hidden_dir", "$srcUsb\System Volume Information" -Force | Out-Null
    'hello world' | Out-File "$srcUsb\readme.txt" -Encoding UTF8
    'report data' | Out-File "$srcUsb\docs\report.txt" -Encoding UTF8
    'secret file' | Out-File "$srcUsb\hidden.txt" -Encoding UTF8
    'system file' | Out-File "$srcUsb\sys.txt" -Encoding UTF8
    'inside hidden' | Out-File "$srcUsb\hidden_dir\inside.txt" -Encoding UTF8
    'indexer' | Out-File "$srcUsb\System Volume Information\IndexerVolumeGuid" -Encoding UTF8

    & attrib.exe +H "$srcUsb\hidden.txt"
    & attrib.exe +S "$srcUsb\sys.txt"
    & attrib.exe +H "$srcUsb\hidden_dir"
    & attrib.exe +S +H "$srcUsb\System Volume Information"
    & attrib.exe +S +H "$srcUsb"

    $dstExcluded = Join-Path $tempWorkspace 'backup_excluded\TEST_2026'
    $logExcluded = Join-Path $tempWorkspace 'backup_excluded\logs\TEST_2026.log'
    $watcherLog = Join-Path $tempWorkspace 'backup_excluded\logs\usb-backup.log'

    $resExcl = Invoke-DirectoryRobocopy `
        -SourcePath $srcUsb `
        -DestinationPath $dstExcluded `
        -RobocopyLogPath $logExcluded `
        -IncludeHiddenSystem $false `
        -Retries 1 `
        -WaitSeconds 1 `
        -WatcherLogPath $watcherLog

    Assert-True (-not $resExcl.HasErrors) "Robocopy (default exclude hidden/system) succeeded with ExitCode=$($resExcl.ExitCode)"
    Assert-True (Test-Path -LiteralPath "$dstExcluded\readme.txt") 'Normal root file copied'
    Assert-True (Test-Path -LiteralPath "$dstExcluded\docs\report.txt") 'Normal subdirectory file copied'
    Assert-True (-not (Test-Path -LiteralPath "$dstExcluded\hidden.txt")) 'Hidden file excluded by default'
    Assert-True (-not (Test-Path -LiteralPath "$dstExcluded\sys.txt")) 'System file excluded by default'
    Assert-True (-not (Test-Path -LiteralPath "$dstExcluded\hidden_dir")) 'Hidden directory excluded by default'
    Assert-True (-not (Test-Path -LiteralPath "$dstExcluded\System Volume Information")) 'System Volume Information excluded by default'

    $dstAttrs = [System.IO.File]::GetAttributes($dstExcluded)
    $hsMask = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    Assert-Equal 0 ([int]($dstAttrs -band $hsMask)) 'Destination backup folder remains visible (no H/S inherited from source root)'

    Assert-True (Test-Path -LiteralPath $logExcluded) 'Per-backup robocopy log created under backup folder'
    $logText = Get-Content -LiteralPath $logExcluded -Raw
    Assert-True ($logText -match 'readme\.txt' -and $logText -match 'report\.txt') 'Backup log lists copied files'
    Assert-True ($logText -match 'ExitCode\s*:\s*1\s*\(SUCCESS\)') 'Backup log records exit code and status'

    $dstIncluded = Join-Path $tempWorkspace 'backup_included\TEST_2026'
    $logIncluded = Join-Path $tempWorkspace 'backup_included\logs\TEST_2026.log'
    $resIncl = Invoke-DirectoryRobocopy `
        -SourcePath $srcUsb `
        -DestinationPath $dstIncluded `
        -RobocopyLogPath $logIncluded `
        -IncludeHiddenSystem $true `
        -Retries 1 `
        -WaitSeconds 1 `
        -WatcherLogPath $watcherLog

    Assert-True (-not $resIncl.HasErrors) "Robocopy (includeHiddenSystem=true) succeeded with ExitCode=$($resIncl.ExitCode)"
    Assert-True (Test-Path -LiteralPath "$dstIncluded\hidden.txt") 'Hidden file copied when includeHiddenSystem=true'
    Assert-True (Test-Path -LiteralPath "$dstIncluded\sys.txt") 'System file copied when includeHiddenSystem=true'
    Assert-True (Test-Path -LiteralPath "$dstIncluded\hidden_dir\inside.txt") 'Hidden directory contents copied when includeHiddenSystem=true'

    Write-Host '5. DryRun non-destructive test'
    $dstDry = Join-Path $tempWorkspace 'backup_dry\TEST_DRY'
    $logDry = Join-Path $tempWorkspace 'backup_dry\logs\dryrun.log'
    $resDry = Invoke-DirectoryRobocopy `
        -SourcePath $srcUsb `
        -DestinationPath $dstDry `
        -RobocopyLogPath $logDry `
        -IncludeHiddenSystem $false `
        -DryRun `
        -WatcherLogPath $watcherLog
    Assert-True (-not $resDry.HasErrors) 'DryRun robocopy completed without errors'
    Assert-True (-not (Test-Path -LiteralPath $dstDry)) 'DryRun did not create backup destination folder'
    Assert-True (Test-Path -LiteralPath $logDry) 'DryRun wrote simulation log'

    Write-Host '6. Unplug/replug drive state tracking'
    $script:mockCallCount = 0
    $script:mockReadyDrives = @()
    function Get-ReadyRemovableDrives { return $script:mockReadyDrives }
    function Invoke-DriveBackup {
        param($Drive, $BackupRoot, $Config, $WatcherLogPath, [switch]$DryRun, [switch]$ToConsole)
        $script:mockCallCount++
        return [PSCustomObject]@{ DeviceID = $Drive.DeviceID; HasErrors = $false }
    }

    $tracked = @{}
    $stateCfg = Import-UsbBackupConfig -Path $configFile
    $stateLog = Join-Path $tempWorkspace 'state_watcher.log'
    $driveA1 = [PSCustomObject]@{ DeviceID = 'Z:'; RootPath = 'Z:\'; VolumeName = 'STICK1'; VolumeSerialNumber = 'AAAA1111'; FileSystem = 'FAT32'; SizeBytes = 1024 }
    $driveA2 = [PSCustomObject]@{ DeviceID = 'Z:'; RootPath = 'Z:\'; VolumeName = 'STICK2'; VolumeSerialNumber = 'BBBB2222'; FileSystem = 'exFAT'; SizeBytes = 2048 }

    $script:mockReadyDrives = @($driveA1)
    $null = Update-TrackedDrivesState -TrackedDrives $tracked -CurrentDrives $script:mockReadyDrives -BackupRoot $tempWorkspace -Config $stateCfg -WatcherLogPath $stateLog
    Assert-Equal 1 $script:mockCallCount 'First insertion triggers backup'

    $null = Update-TrackedDrivesState -TrackedDrives $tracked -CurrentDrives $script:mockReadyDrives -BackupRoot $tempWorkspace -Config $stateCfg -WatcherLogPath $stateLog
    Assert-Equal 1 $script:mockCallCount 'Keeping drive plugged in does not trigger duplicate backup'

    $script:mockReadyDrives = @()
    $null = Update-TrackedDrivesState -TrackedDrives $tracked -CurrentDrives $script:mockReadyDrives -BackupRoot $tempWorkspace -Config $stateCfg -WatcherLogPath $stateLog
    Assert-Equal 0 $tracked.Count 'Unplugging forgets drive from tracked state'

    $script:mockReadyDrives = @($driveA1)
    $null = Update-TrackedDrivesState -TrackedDrives $tracked -CurrentDrives $script:mockReadyDrives -BackupRoot $tempWorkspace -Config $stateCfg -WatcherLogPath $stateLog
    Assert-Equal 2 $script:mockCallCount 'Reinserting same drive triggers new backup'

    $script:mockReadyDrives = @($driveA2)
    $null = Update-TrackedDrivesState -TrackedDrives $tracked -CurrentDrives $script:mockReadyDrives -BackupRoot $tempWorkspace -Config $stateCfg -WatcherLogPath $stateLog
    Assert-Equal 3 $script:mockCallCount 'Swapping drive serial on same letter triggers new backup'

    Write-Host '7. CLI -Once -DryRun invocation'
    $cliBackupRoot = Join-Path $tempWorkspace 'cli_dry_root'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript -Once -DryRun -BackupRoot $cliBackupRoot | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'usb-backup.ps1 -Once -DryRun exits cleanly with code 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $cliBackupRoot 'logs\usb-backup.log')) 'CLI execution creates watcher log'

    Write-Host '8. End-to-end setup.ps1 and uninstall.ps1 Scheduled Task verification'
    $taskBackupRoot = Join-Path $tempWorkspace 'task_backups'
    $tempConfigPath = Join-Path $tempWorkspace 'test_config.json'
    @{
        taskName                = $testTaskName
        backupRootPath          = $taskBackupRoot
        includeHiddenSystem     = $false
        backupExistingOnStartup = $false
        pollIntervalSeconds     = 2
    } | ConvertTo-Json | Out-File -LiteralPath $tempConfigPath -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript -ConfigPath $tempConfigPath -TaskName $testTaskName | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'setup.ps1 exits with code 0 without admin privileges'

    $regTask = Get-ScheduledTask -TaskName $testTaskName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $regTask) 'Scheduled Task was created'
    Assert-Equal 'Limited' ([string]$regTask.Principal.RunLevel) 'Task Principal RunLevel is Limited (non-admin)'
    Assert-Equal 'Interactive' ([string]$regTask.Principal.LogonType) 'Task Principal LogonType is Interactive (current user session)'
    Assert-Equal 'PT0S' ([string]$regTask.Settings.ExecutionTimeLimit) 'Task ExecutionTimeLimit is PT0S (unlimited)'
    Assert-Equal 'Running' ([string]$regTask.State) 'setup.ps1 started the Scheduled Task immediately'

    Start-Sleep -Seconds 2
    $taskWatcherLog = Join-Path $taskBackupRoot 'logs\usb-backup.log'
    Assert-True (Test-Path -LiteralPath $taskWatcherLog) 'Scheduled Task process wrote watcher log on startup'

    # Place a dummy backup artifact to confirm uninstall leaves backups intact.
    $dummyBackupDir = Join-Path $taskBackupRoot 'PRESERVE_ME_2026'
    New-Item -ItemType Directory -Path $dummyBackupDir -Force | Out-Null
    'important backup' | Out-File -LiteralPath (Join-Path $dummyBackupDir 'keep.txt') -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstallScript -ConfigPath $tempConfigPath -TaskName $testTaskName | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'uninstall.ps1 exits with code 0'

    $afterUninstall = Get-ScheduledTask -TaskName $testTaskName -ErrorAction SilentlyContinue
    Assert-True ($null -eq $afterUninstall) 'uninstall.ps1 removed the Scheduled Task'
    Assert-True (Test-Path -LiteralPath (Join-Path $dummyBackupDir 'keep.txt')) 'uninstall.ps1 left existing backups intact'

    Write-Host '9. Zero-argument setup.ps1 / uninstall.ps1 default config resolution test'
    $clonedRepo = Join-Path $tempWorkspace 'cloned repo with spaces'
    New-Item -ItemType Directory -Path $clonedRepo -Force | Out-Null
    Copy-Item -LiteralPath $mainScript, $setupScript, $uninstallScript -Destination $clonedRepo
    $zeroArgTaskName = "${testTaskName}_ZeroArg"
    $zeroArgBackupRoot = Join-Path $tempWorkspace 'zero_arg_backups'
    @{
        taskName       = $zeroArgTaskName
        backupRootPath = $zeroArgBackupRoot
    } | ConvertTo-Json | Out-File -LiteralPath (Join-Path $clonedRepo 'config.json') -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clonedRepo 'setup.ps1') | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'Zero-arg setup.ps1 (path with spaces, default config.json) succeeds'
    $zeroTask = Get-ScheduledTask -TaskName $zeroArgTaskName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $zeroTask) 'Zero-arg setup.ps1 registered task using taskName from config.json'
    Assert-Equal 'Running' ([string]$zeroTask.State) 'Zero-arg setup.ps1 started task from path with spaces'
    Start-Sleep -Seconds 2
    Assert-True (Test-Path -LiteralPath (Join-Path $zeroArgBackupRoot 'logs\usb-backup.log')) 'Zero-arg task from path with spaces wrote watcher log'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clonedRepo 'uninstall.ps1') | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'Zero-arg uninstall.ps1 succeeds'
    Assert-True ($null -eq (Get-ScheduledTask -TaskName $zeroArgTaskName -ErrorAction SilentlyContinue)) 'Zero-arg uninstall.ps1 removed task read from config.json'
}
finally {
    # Ensure cleanup even if an assertion failed.
    foreach ($cleanupName in @($testTaskName, "${testTaskName}_ZeroArg")) {
        $leftover = Get-ScheduledTask -TaskName $cleanupName -ErrorAction SilentlyContinue
        if ($null -ne $leftover) {
            if ($leftover.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $cleanupName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
            Unregister-ScheduledTask -TaskName $cleanupName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $tempWorkspace) {
        Remove-Item -LiteralPath $tempWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "Test summary: $passed passed, $failed failed."
if ($failed -gt 0) {
    exit 1
}
exit 0
