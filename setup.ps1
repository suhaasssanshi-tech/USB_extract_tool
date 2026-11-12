<#
.SYNOPSIS
    Installs and starts the Personal USB Backup Helper for the current Windows user.

.DESCRIPTION
    Configures a user-scoped Windows Scheduled Task (AtLogOn for the current user
    only, Limited run level, Interactive logon type — no Administrator/SYSTEM
    privileges and no machine-wide service), creates the Desktop backup folder,
    and starts the background helper immediately.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TaskName,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$mainScriptPath = Join-Path $repoRoot 'usb-backup.ps1'
$resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $repoRoot 'config.json'
}
elseif ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
}
else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ConfigPath))
}

if (-not (Test-Path -LiteralPath $mainScriptPath)) {
    throw "Main script not found at '$mainScriptPath'."
}

# Verify built-in robocopy.exe is available.
$robocopyCmd = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
if ($null -eq $robocopyCmd) {
    throw 'Built-in Windows tool robocopy.exe was not found in PATH.'
}

# Load shared helpers without executing the watcher loop.
. $mainScriptPath

$config = Import-UsbBackupConfig -Path $resolvedConfigPath
$resolvedTaskName = if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName.Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace($config.taskName)) {
    $config.taskName.Trim()
}
else {
    'PersonalUsbBackupHelper'
}

$backupRoot = Resolve-BackupRootPath -ConfiguredPath $config.backupRootPath
$logsDir = Join-Path $backupRoot 'logs'

if (-not (Test-Path -LiteralPath $backupRoot)) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) {
    $psExe = 'powershell.exe'
}

# Stop an existing task/process cleanly if setup.ps1 is re-run.
$existingTask = Get-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask -and $existingTask.State -eq 'Running') {
    Write-Host "Stopping existing '$resolvedTaskName' task before updating..."
    Stop-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        $t = Get-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
        if ($null -eq $t -or $t.State -ne 'Running') {
            break
        }
    }
}

$escapedScript = $mainScriptPath.Replace('"', '\"')
$escapedConfig = $resolvedConfigPath.Replace('"', '\"')
$taskArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$escapedScript`" -ConfigPath `"$escapedConfig`""

$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument $taskArgs `
    -WorkingDirectory $repoRoot

# Scope trigger and principal strictly to the current logged-in user (no admin, no SYSTEM).
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

$description = 'Personal USB Backup Helper: copies inserted removable drives (DriveType=2) to Desktop\USB_Backups for the current user.'

Register-ScheduledTask `
    -TaskName $resolvedTaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description $description `
    -Force | Out-Null

Write-Host ''
Write-Host "Scheduled Task '$resolvedTaskName' registered for user '$currentUser' (Limited / Interactive)." -ForegroundColor Green

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $resolvedTaskName
    Start-Sleep -Seconds 2
}

$registeredTask = Get-ScheduledTask -TaskName $resolvedTaskName
Write-Host "Task State    : $($registeredTask.State)"
Write-Host "Backup Folder : $backupRoot"
Write-Host "Logs Folder   : $logsDir"
Write-Host "Config File   : $resolvedConfigPath"
Write-Host ''
Write-Host 'Useful commands:'
Write-Host "  Verify status : Get-ScheduledTask -TaskName '$resolvedTaskName'"
Write-Host "  Stop now      : Stop-ScheduledTask -TaskName '$resolvedTaskName'"
Write-Host "  Disable       : Disable-ScheduledTask -TaskName '$resolvedTaskName'"
Write-Host "  Enable        : Enable-ScheduledTask -TaskName '$resolvedTaskName'"
Write-Host "  Uninstall     : .\uninstall.ps1"
