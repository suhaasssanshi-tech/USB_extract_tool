<#
.SYNOPSIS
    Personal removable USB drive backup helper for Windows 10/11.

.DESCRIPTION
    Monitors for removable USB drives (DriveType = 2) in the current user's
    session and copies their contents into a timestamped folder on the Desktop
    (or configured backup root) using built-in Windows PowerShell and robocopy.

    Safety guarantees:
      - Only processes removable drives (DriveType = 2); never internal or system drives.
      - Never executes any files from USB drives.
      - Skips hidden and system files/directories unless explicitly enabled in config.
      - Runs strictly in the current user's session (no admin/SYSTEM privileges required).
      - Tracks removed drives so unplugging and replugging triggers a fresh backup.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BackupRoot,
    [switch]$Once,
    [switch]$DryRun,
    [switch]$IncludeHiddenSystem,
    [switch]$SkipInitialDrives,
    [switch]$NoEventSubscription,
    [switch]$Console,
    [int]$MaxIterations = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultConfig {
    <#
    .SYNOPSIS
        Returns default configuration values.
    #>
    return [ordered]@{
        taskName                = 'PersonalUsbBackupHelper'
        backupRootPath          = ''
        includeHiddenSystem     = $false
        backupExistingOnStartup = $true
        pollIntervalSeconds     = 3
        settleDelayMs           = 1500
        robocopyRetries         = 2
        robocopyWaitSeconds     = 1
        excludeDirectories      = @()
        timestampFormat         = 'yyyy-MM-dd_HH-mm-ss'
    }
}

function Import-UsbBackupConfig {
    <#
    .SYNOPSIS
        Loads config.json (and optional config.local.json) merged over defaults.
    #>
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $config = Get-DefaultConfig
    $candidatePaths = @()

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidatePaths += $Path
        $dir = Split-Path -Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $localOverride = Join-Path $dir 'config.local.json'
            if (Test-Path -LiteralPath $localOverride) {
                $candidatePaths += $localOverride
            }
        }
    }

    foreach ($cfgPath in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            continue
        }

        $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }

        $parsed = $raw | ConvertFrom-Json
        foreach ($prop in $parsed.PSObject.Properties) {
            if ($config.Contains($prop.Name)) {
                $config[$prop.Name] = $prop.Value
            }
        }
    }

    if ([int]$config.pollIntervalSeconds -lt 1) {
        $config.pollIntervalSeconds = 1
    }
    if ([int]$config.settleDelayMs -lt 0) {
        $config.settleDelayMs = 0
    }
    if ([int]$config.robocopyRetries -lt 0) {
        $config.robocopyRetries = 0
    }
    if ([int]$config.robocopyWaitSeconds -lt 0) {
        $config.robocopyWaitSeconds = 0
    }
    if ([string]::IsNullOrWhiteSpace($config.timestampFormat)) {
        $config.timestampFormat = 'yyyy-MM-dd_HH-mm-ss'
    }
    if ($null -eq $config.excludeDirectories) {
        $config.excludeDirectories = @()
    }

    return [PSCustomObject]$config
}

function Resolve-BackupRootPath {
    <#
    .SYNOPSIS
        Resolves the backup root directory without hardcoded usernames or drive letters.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath,
        [string]$OverridePath
    )

    $candidate = if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $OverridePath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $ConfiguredPath
    }
    else {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktop)) {
            $desktop = Join-Path $env:USERPROFILE 'Desktop'
        }
        Join-Path $desktop 'USB_Backups'
    }

    return [Environment]::ExpandEnvironmentVariables($candidate.Trim())
}

function Write-HelperLog {
    <#
    .SYNOPSIS
        Appends a timestamped log line to the watcher log and optionally writes to console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [string]$LogFilePath,
        [switch]$ToConsole
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        $logDir = Split-Path -Path $LogFilePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFilePath -Value $line -Encoding UTF8
    }

    if ($ToConsole) {
        Write-Host $line
    }
}

function Get-SafeVolumeLabel {
    <#
    .SYNOPSIS
        Sanitizes a USB volume label into a safe Windows folder name component.
    #>
    [CmdletBinding()]
    param(
        [string]$VolumeName,
        [string]$DriveId = 'USB'
    )

    $letter = ($DriveId -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = 'DRIVE'
    }

    $fallback = "USB_$letter"
    if ([string]::IsNullOrWhiteSpace($VolumeName)) {
        return $fallback
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $VolumeName.ToCharArray()) {
        if ($invalidChars -contains $ch -or [char]::IsControl($ch)) {
            $null = $builder.Append('_')
        }
        else {
            $null = $builder.Append($ch)
        }
    }

    $clean = $builder.ToString()
    $clean = $clean -replace '\s+', '_'
    $clean = $clean -replace '_+', '_'
    $clean = $clean.Trim(' ', '.', '_')

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $fallback
    }

    if ($clean -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $clean = "USB_$clean"
    }

    if ($clean.Length -gt 64) {
        $clean = $clean.Substring(0, 64).TrimEnd('_', '.')
    }

    return $clean
}

function Get-UniqueBackupFolderName {
    <#
    .SYNOPSIS
        Generates a unique <label>_<timestamp> folder name under BackupRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        [string]$SafeLabel,
        [string]$TimestampFormat = 'yyyy-MM-dd_HH-mm-ss'
    )

    $stamp = (Get-Date).ToString($TimestampFormat)
    $baseName = "${SafeLabel}_${stamp}"
    $candidateName = $baseName
    $counter = 1

    while (Test-Path -LiteralPath (Join-Path $BackupRoot $candidateName)) {
        $candidateName = "${baseName}_$counter"
        $counter++
    }

    return $candidateName
}

function Get-ReadyRemovableDrives {
    <#
    .SYNOPSIS
        Returns currently mounted, ready removable drives (DriveType = 2 only).
    #>
    [CmdletBinding()]
    param()

    $results = @()
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\').ToUpperInvariant() } else { 'C:' }

    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 2' -ErrorAction Stop
    foreach ($disk in $disks) {
        if ($null -eq $disk -or [int]$disk.DriveType -ne 2) {
            continue
        }

        $deviceId = [string]$disk.DeviceID
        if ([string]::IsNullOrWhiteSpace($deviceId) -or $deviceId -notmatch '^[A-Za-z]:$') {
            continue
        }

        $normalizedId = $deviceId.ToUpperInvariant()
        if ($normalizedId -eq $systemDrive) {
            continue
        }

        if ($null -eq $disk.Size -or [int64]$disk.Size -le 0) {
            continue
        }

        try {
            $driveInfo = New-Object System.IO.DriveInfo($normalizedId)
            if ($driveInfo.DriveType -ne [System.IO.DriveType]::Removable -or -not $driveInfo.IsReady) {
                continue
            }
        }
        catch {
            continue
        }

        $rootPath = "$normalizedId\"
        if (-not (Test-Path -LiteralPath $rootPath)) {
            continue
        }

        $results += [PSCustomObject]@{
            DeviceID           = $normalizedId
            RootPath           = $rootPath
            VolumeName         = [string]$disk.VolumeName
            VolumeSerialNumber = [string]$disk.VolumeSerialNumber
            FileSystem         = [string]$disk.FileSystem
            SizeBytes          = [int64]$disk.Size
        }
    }

    return $results
}

function Get-HiddenOrSystemDirectories {
    <#
    .SYNOPSIS
        Enumerates directory subtrees under SourcePath marked Hidden or System,
        stopping descent at each hidden/system or reparse-point root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    $excluded = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $normalizedRoot = $SourcePath.TrimEnd('\')
    if ($normalizedRoot -match '^[A-Za-z]:$') {
        $normalizedRoot = "$normalizedRoot\"
    }

    foreach ($wellKnown in @('System Volume Information', '$RECYCLE.BIN')) {
        $wkPath = Join-Path $normalizedRoot $wellKnown
        if ($seen.Add($wkPath)) {
            $excluded.Add($wkPath)
        }
    }

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($normalizedRoot)

    $hiddenOrSystemMask = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    $reparseMask = [System.IO.FileAttributes]::ReparsePoint

    while ($queue.Count -gt 0) {
        $currentDir = $queue.Dequeue()
        $children = $null
        try {
            $children = [System.IO.Directory]::EnumerateDirectories($currentDir)
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            try {
                $attrs = [System.IO.File]::GetAttributes($child)
            }
            catch {
                continue
            }

            if (($attrs -band $hiddenOrSystemMask) -ne 0) {
                if ($seen.Add($child)) {
                    $excluded.Add($child)
                }
                continue
            }

            if (($attrs -band $reparseMask) -ne 0) {
                # Do not traverse junctions/symlinks; robocopy /XJ skips them.
                continue
            }

            $queue.Enqueue($child)
        }
    }

    return $excluded.ToArray()
}

function Clear-HiddenSystemAttributes {
    <#
    .SYNOPSIS
        Ensures the created backup folder itself is visible (clears H/S attributes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $current = [System.IO.File]::GetAttributes($Path)
        $cleaned = $current -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System))
        if ($cleaned -ne $current) {
            [System.IO.File]::SetAttributes($Path, $cleaned)
        }
    }
    catch {
        # Best-effort attribute cleanup; non-fatal.
    }
}

function Invoke-DirectoryRobocopy {
    <#
    .SYNOPSIS
        Copies files from SourcePath to DestinationPath via robocopy and records logs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [Parameter(Mandatory)]
        [string]$RobocopyLogPath,
        [bool]$IncludeHiddenSystem = $false,
        [string[]]$ExcludeDirectories = @(),
        [int]$Retries = 2,
        [int]$WaitSeconds = 1,
        [switch]$DryRun,
        [string]$WatcherLogPath,
        [switch]$ToConsole
    )

    # Trailing "\." prevents Windows command-line argument parsing from treating
    # a trailing "\" before a closing quote as an escaped literal quote.
    $trimmedSource = $SourcePath.TrimEnd('\')
    $sourceArg = "$trimmedSource\."
    $destArg = $DestinationPath.TrimEnd('\')

    $logDir = Split-Path -Path $RobocopyLogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    if (-not $DryRun -and -not (Test-Path -LiteralPath $destArg)) {
        New-Item -ItemType Directory -Path $destArg -Force | Out-Null
    }

    $headerLines = @(
        "============================================================"
        "USB Backup Job Log"
        "Timestamp          : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Source             : $SourcePath"
        "Destination        : $destArg"
        "Mode               : $(if ($DryRun) { 'DRY RUN (/L - no files copied)' } else { 'COPY' })"
        "IncludeHiddenSystem: $IncludeHiddenSystem"
        "============================================================"
    )
    $headerLines | Out-File -LiteralPath $RobocopyLogPath -Encoding Unicode

    $rcArgs = New-Object System.Collections.Generic.List[string]
    $rcArgs.Add($sourceArg)
    $rcArgs.Add($destArg)
    $rcArgs.Add('/E')
    $rcArgs.Add('/COPY:DAT')
    $rcArgs.Add('/DCOPY:DA')
    $rcArgs.Add('/XJ')
    $rcArgs.Add("/R:$Retries")
    $rcArgs.Add("/W:$WaitSeconds")
    $rcArgs.Add('/NP')

    if (-not $IncludeHiddenSystem) {
        $rcArgs.Add('/XA:SH')
    }

    if ($DryRun) {
        $rcArgs.Add('/L')
    }
    if ($ToConsole) {
        $rcArgs.Add('/TEE')
    }

    $xdList = New-Object System.Collections.Generic.List[string]
    $xdSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if (-not $IncludeHiddenSystem) {
        $hiddenDirs = Get-HiddenOrSystemDirectories -SourcePath $SourcePath
        foreach ($hd in $hiddenDirs) {
            if (-not [string]::IsNullOrWhiteSpace($hd) -and $xdSeen.Add($hd)) {
                $xdList.Add($hd)
            }
        }
    }

    foreach ($userExcl in $ExcludeDirectories) {
        if (-not [string]::IsNullOrWhiteSpace($userExcl) -and $xdSeen.Add($userExcl)) {
            $xdList.Add($userExcl)
        }
    }

    $tempJobFile = $null
    try {
        if ($xdList.Count -gt 0) {
            $xdCharLength = ($xdList | ForEach-Object { $_.Length + 3 } | Measure-Object -Sum).Sum
            if ($xdCharLength -gt 20000) {
                # Fall back to a robocopy job file when many excluded dirs would exceed CreateProcess command-line limits.
                $tempJobFile = Join-Path $env:TEMP "usb_backup_$([Guid]::NewGuid().ToString('N')).rcj"
                $jobLines = New-Object System.Collections.Generic.List[string]
                $jobLines.Add('/XD')
                foreach ($dir in $xdList) {
                    $jobLines.Add("`t$dir")
                }
                $jobLines | Out-File -LiteralPath $tempJobFile -Encoding Default
                $rcArgs.Add("/JOB:$tempJobFile")
            }
            else {
                $rcArgs.Add('/XD')
                foreach ($dir in $xdList) {
                    $rcArgs.Add($dir)
                }
            }
        }

        $rcArgs.Add("/UNILOG+:$RobocopyLogPath")

        if ($ToConsole) {
            & robocopy.exe @rcArgs | Out-Host
        }
        else {
            & robocopy.exe @rcArgs | Out-Null
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($tempJobFile -and (Test-Path -LiteralPath $tempJobFile)) {
            Remove-Item -LiteralPath $tempJobFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $DryRun) {
        Clear-HiddenSystemAttributes -Path $destArg
    }

    $hasErrors = ($exitCode -ge 8)
    $footerLines = @(
        ""
        "------------------------------------------------------------"
        "Finished : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "ExitCode : $exitCode ($(if ($hasErrors) { 'ERRORS OCCURRED' } else { 'SUCCESS' }))"
        "------------------------------------------------------------"
    )
    $footerLines | Out-File -LiteralPath $RobocopyLogPath -Append -Encoding Unicode

    $summaryMsg = "Robocopy finished for '$SourcePath' -> '$destArg' (ExitCode=$exitCode, Log='$RobocopyLogPath')"
    if ($hasErrors) {
        Write-HelperLog -Message "$summaryMsg. Some files or directories failed to copy." -Level 'ERROR' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
    }
    else {
        Write-HelperLog -Message $summaryMsg -Level 'INFO' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
    }

    return [PSCustomObject]@{
        SourcePath      = $SourcePath
        DestinationPath = $destArg
        LogPath         = $RobocopyLogPath
        ExitCode        = $exitCode
        HasErrors       = $hasErrors
        DryRun          = [bool]$DryRun
    }
}

function Invoke-DriveBackup {
    <#
    .SYNOPSIS
        Orchestrates backing up a single detected removable drive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Drive,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory)]
        [string]$WatcherLogPath,
        [switch]$DryRun,
        [switch]$ToConsole
    )

    $safeLabel = Get-SafeVolumeLabel -VolumeName $Drive.VolumeName -DriveId $Drive.DeviceID
    $folderName = Get-UniqueBackupFolderName -BackupRoot $BackupRoot -SafeLabel $safeLabel -TimestampFormat $Config.timestampFormat
    $destinationPath = Join-Path $BackupRoot $folderName

    $logPrefix = if ($DryRun) { "dryrun_$folderName" } else { $folderName }
    $robocopyLogPath = Join-Path (Join-Path $BackupRoot 'logs') "$logPrefix.log"

    Write-HelperLog -Message "Detected removable drive $($Drive.DeviceID) (Label='$($Drive.VolumeName)', Serial='$($Drive.VolumeSerialNumber)', FS='$($Drive.FileSystem)'). Starting $(if ($DryRun) { 'dry-run' } else { 'backup' }) to '$destinationPath'." `
        -Level 'INFO' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole

    return Invoke-DirectoryRobocopy `
        -SourcePath $Drive.RootPath `
        -DestinationPath $destinationPath `
        -RobocopyLogPath $robocopyLogPath `
        -IncludeHiddenSystem ([bool]$Config.includeHiddenSystem) `
        -ExcludeDirectories ([string[]]$Config.excludeDirectories) `
        -Retries ([int]$Config.robocopyRetries) `
        -WaitSeconds ([int]$Config.robocopyWaitSeconds) `
        -DryRun:$DryRun `
        -WatcherLogPath $WatcherLogPath `
        -ToConsole:$ToConsole
}

function Update-TrackedDrivesState {
    <#
    .SYNOPSIS
        Reconciles currently attached removable drives with tracked drives state,
        forgetting removed or swapped drives and backing up newly detected ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TrackedDrives,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CurrentDrives,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory)]
        [string]$WatcherLogPath,
        [switch]$SkipBackup,
        [switch]$DryRun,
        [switch]$ToConsole
    )

    $currentById = @{}
    foreach ($drv in $CurrentDrives) {
        if ($null -ne $drv -and -not [string]::IsNullOrWhiteSpace($drv.DeviceID)) {
            $currentById[$drv.DeviceID] = $drv
        }
    }

    # Forget drives that were unplugged or replaced by a different volume on the same letter.
    foreach ($trackedId in @($TrackedDrives.Keys)) {
        if (-not $currentById.ContainsKey($trackedId)) {
            $TrackedDrives.Remove($trackedId)
            Write-HelperLog -Message "Removable drive $trackedId disconnected; forgotten so reinserting will trigger a new backup." `
                -Level 'INFO' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
            continue
        }

        $prevSerial = $TrackedDrives[$trackedId].VolumeSerialNumber
        $currSerial = $currentById[$trackedId].VolumeSerialNumber
        if ($prevSerial -ne $currSerial) {
            $TrackedDrives.Remove($trackedId)
            Write-HelperLog -Message "Removable drive $trackedId volume serial changed ('$prevSerial' -> '$currSerial'); treating as newly inserted drive." `
                -Level 'INFO' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
        }
    }

    $results = @()
    foreach ($drive in ($CurrentDrives | Sort-Object DeviceID)) {
        if ($TrackedDrives.ContainsKey($drive.DeviceID)) {
            continue
        }

        if ($SkipBackup) {
            $TrackedDrives[$drive.DeviceID] = [PSCustomObject]@{
                VolumeSerialNumber = $drive.VolumeSerialNumber
                BackedUpAt         = $null
                SkippedOnStartup   = $true
            }
            Write-HelperLog -Message "Skipping already-connected removable drive $($drive.DeviceID) on startup (backupExistingOnStartup=false)." `
                -Level 'INFO' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
            continue
        }

        try {
            $res = Invoke-DriveBackup `
                -Drive $drive `
                -BackupRoot $BackupRoot `
                -Config $Config `
                -WatcherLogPath $WatcherLogPath `
                -DryRun:$DryRun `
                -ToConsole:$ToConsole
            $results += $res

            # Verify the same drive is still mounted before marking it tracked;
            # if unplugged mid-backup, leave it untracked so an immediate replug works.
            $stillReady = $false
            try {
                $recheck = @(Get-ReadyRemovableDrives | Where-Object {
                    $_.DeviceID -eq $drive.DeviceID -and $_.VolumeSerialNumber -eq $drive.VolumeSerialNumber
                })
                $stillReady = ($recheck.Count -gt 0)
            }
            catch {
                $stillReady = $false
            }

            if ($stillReady) {
                $TrackedDrives[$drive.DeviceID] = [PSCustomObject]@{
                    VolumeSerialNumber = $drive.VolumeSerialNumber
                    BackedUpAt         = Get-Date
                    SkippedOnStartup   = $false
                }
            }
            else {
                Write-HelperLog -Message "Drive $($drive.DeviceID) was disconnected before or right after backup finished; keeping untracked for next insertion." `
                    -Level 'WARN' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
            }
        }
        catch {
            Write-HelperLog -Message "Failed to back up drive $($drive.DeviceID): $($_.Exception.Message)" `
                -Level 'ERROR' -LogFilePath $WatcherLogPath -ToConsole:$ToConsole
        }
    }

    return $results
}

function Start-UsbBackupWatcher {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$OverrideBackupRoot,
        [switch]$Once,
        [switch]$DryRun,
        [switch]$IncludeHiddenSystemOverride,
        [switch]$SkipInitialDrivesOverride,
        [switch]$NoEventSubscription,
        [switch]$ToConsole,
        [int]$MaxIterations = 0
    )

    $config = Import-UsbBackupConfig -Path $ConfigPath
    if ($IncludeHiddenSystemOverride) {
        $config.includeHiddenSystem = $true
    }
    if ($SkipInitialDrivesOverride) {
        $config.backupExistingOnStartup = $false
    }

    $backupRoot = Resolve-BackupRootPath -ConfiguredPath $config.backupRootPath -OverridePath $OverrideBackupRoot
    $logsDir = Join-Path $backupRoot 'logs'
    $watcherLogPath = Join-Path $logsDir 'usb-backup.log'

    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $logsDir)) {
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        }
    }

    $mutex = $null
    $ownsMutex = $false
    if (-not $Once) {
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutexName = "Local\PersonalUsbBackupHelper_$userSid"
        $createdNew = $false
        $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
        if (-not $createdNew) {
            Write-HelperLog -Message "Another Personal USB Backup Helper instance is already running for this user session. Exiting duplicate instance." `
                -Level 'WARN' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
            $mutex.Dispose()
            return 0
        }
        $ownsMutex = $true
    }

    $eventSourceId = "PersonalUsbBackup_VolChange_$([Guid]::NewGuid().ToString('N'))"
    $eventSubscribed = $false
    $trackedDrives = @{}
    $exitCode = 0

    try {
        Write-HelperLog -Message "USB Backup Helper started (PID=$PID, User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name), BackupRoot='$backupRoot', IncludeHiddenSystem=$($config.includeHiddenSystem), Once=$Once, DryRun=$DryRun)." `
            -Level 'INFO' -LogFilePath $watcherLogPath -ToConsole:$ToConsole

        if (-not $Once -and -not $NoEventSubscription) {
            try {
                $null = Register-CimIndicationEvent -Query 'SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2 OR EventType = 3' -SourceIdentifier $eventSourceId -ErrorAction Stop
                $eventSubscribed = $true
                Write-HelperLog -Message "Subscribed to Windows volume arrival/removal events (polling fallback every $($config.pollIntervalSeconds)s)." `
                    -Level 'INFO' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
            }
            catch {
                Write-HelperLog -Message "Volume event subscription unavailable ($($_.Exception.Message)); falling back to $($config.pollIntervalSeconds)s polling." `
                    -Level 'WARN' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
            }
        }

        # Initial scan on startup.
        $initialDrives = @(Get-ReadyRemovableDrives)
        if ($Once -and $initialDrives.Count -eq 0) {
            Write-HelperLog -Message "No ready removable USB drives (DriveType=2) found." `
                -Level 'INFO' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
        }

        $skipInitial = (-not $Once) -and (-not [bool]$config.backupExistingOnStartup)
        $initialResults = @(Update-TrackedDrivesState `
            -TrackedDrives $trackedDrives `
            -CurrentDrives $initialDrives `
            -BackupRoot $backupRoot `
            -Config $config `
            -WatcherLogPath $watcherLogPath `
            -SkipBackup:$skipInitial `
            -DryRun:$DryRun `
            -ToConsole:$ToConsole)

        if ($Once) {
            if ($initialResults | Where-Object { $_.HasErrors }) {
                $exitCode = 1
            }
            return $exitCode
        }

        $iteration = 0
        while ($true) {
            if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
                break
            }
            $iteration++

            $arrivalSeen = $false
            if ($eventSubscribed) {
                $ev = Wait-Event -SourceIdentifier $eventSourceId -Timeout ([int]$config.pollIntervalSeconds)
                while ($null -ne $ev) {
                    try {
                        $newEvent = $ev.SourceEventArgs.NewEvent
                        $evType = [int]$newEvent.EventType
                        $evDrive = [string]$newEvent.DriveName
                        if ($evType -eq 3 -and -not [string]::IsNullOrWhiteSpace($evDrive)) {
                            $normDrive = $evDrive.TrimEnd('\').ToUpperInvariant()
                            if ($trackedDrives.ContainsKey($normDrive)) {
                                $trackedDrives.Remove($normDrive)
                                Write-HelperLog -Message "Volume removal event received for $normDrive; drive forgotten." `
                                    -Level 'INFO' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
                            }
                        }
                        elseif ($evType -eq 2) {
                            $arrivalSeen = $true
                        }
                    }
                    finally {
                        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
                    }
                    $ev = Wait-Event -SourceIdentifier $eventSourceId -Timeout 0
                }
            }
            else {
                Start-Sleep -Seconds ([int]$config.pollIntervalSeconds)
            }

            if ($arrivalSeen -and [int]$config.settleDelayMs -gt 0) {
                Start-Sleep -Milliseconds ([int]$config.settleDelayMs)
            }

            $currentDrives = @(Get-ReadyRemovableDrives)
            $null = Update-TrackedDrivesState `
                -TrackedDrives $trackedDrives `
                -CurrentDrives $currentDrives `
                -BackupRoot $backupRoot `
                -Config $config `
                -WatcherLogPath $watcherLogPath `
                -DryRun:$DryRun `
                -ToConsole:$ToConsole
        }
    }
    finally {
        if ($eventSubscribed) {
            Unregister-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue
            Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        }
        Write-HelperLog -Message "USB Backup Helper stopped (PID=$PID)." -Level 'INFO' -LogFilePath $watcherLogPath -ToConsole:$ToConsole
        if ($ownsMutex -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }

    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    $resolvedCfg = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $PSScriptRoot 'config.json'
    }
    else {
        $ConfigPath
    }
    $code = Start-UsbBackupWatcher `
        -ConfigPath $resolvedCfg `
        -OverrideBackupRoot $BackupRoot `
        -Once:$Once `
        -DryRun:$DryRun `
        -IncludeHiddenSystemOverride:$IncludeHiddenSystem `
        -SkipInitialDrivesOverride:$SkipInitialDrives `
        -NoEventSubscription:$NoEventSubscription `
        -ToConsole:$Console `
        -MaxIterations $MaxIterations
    exit $code
}
