<#
.SYNOPSIS
    Removes the Personal USB Backup Helper Scheduled Task while leaving backups intact.

.DESCRIPTION
    Stops the running background helper (if active) and unregisters the user-level
    Scheduled Task created by setup.ps1. All backed-up USB files and logs under
    Desktop\USB_Backups (or configured backupRootPath) are preserved untouched.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TaskName
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

$resolvedTaskName = 'PersonalUsbBackupHelper'
$backupRoot = $null

if (Test-Path -LiteralPath $mainScriptPath) {
    . $mainScriptPath
    $config = Import-UsbBackupConfig -Path $resolvedConfigPath
    if ([string]::IsNullOrWhiteSpace($TaskName) -and -not [string]::IsNullOrWhiteSpace($config.taskName)) {
        $resolvedTaskName = $config.taskName.Trim()
    }
    $backupRoot = Resolve-BackupRootPath -ConfiguredPath $config.backupRootPath
}
else {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $env:USERPROFILE 'Desktop'
    }
    $backupRoot = Join-Path $desktop 'USB_Backups'
}

if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
    $resolvedTaskName = $TaskName.Trim()
}

$task = Get-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.State -eq 'Running') {
        Write-Host "Stopping running Scheduled Task '$resolvedTaskName'..."
        Stop-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 500
            $t = Get-ScheduledTask -TaskName $resolvedTaskName -ErrorAction SilentlyContinue
            if ($null -eq $t -or $t.State -ne 'Running') {
                break
            }
        }
    }

    Unregister-ScheduledTask -TaskName $resolvedTaskName -Confirm:$false
    Write-Host "Removed Scheduled Task '$resolvedTaskName'." -ForegroundColor Green
}
else {
    Write-Host "Scheduled Task '$resolvedTaskName' was not found (already uninstalled)." -ForegroundColor Yellow
}

# Ensure no helper process spawned from this repository remains running.
if (Test-Path -LiteralPath $mainScriptPath) {
    $escapedMain = [regex]::Escape($mainScriptPath)
    $strayProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $escapedMain })

    foreach ($proc in $strayProcs) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped helper process PID $($proc.ProcessId)."
        }
        catch {
            Write-Warning "Could not stop process PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
}

Write-Host "Existing backups and logs were left intact at: $backupRoot"
