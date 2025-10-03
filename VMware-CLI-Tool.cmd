<# :: Batch section. Launches PowerShell.

@echo off & setlocal EnableExtensions DisableDelayedExpansion
set ARGS=%*
if defined ARGS set ARGS=%ARGS:"=\"%
if defined ARGS set ARGS=%ARGS:'=''% 
copy "%~f0" "%TEMP%\%~n0.ps1" >NUL && powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%TEMP%\%~n0.ps1" %ARGS%
set "ec=%ERRORLEVEL%" & del "%TEMP%\%~n0.ps1" >NUL
pause
exit /b %ec%

:# End of the PowerShell comment around the Batch section #>

<# vCenter VM Dashboard (Console version)
   - Windows PowerShell 5.1 & PowerShell 7+
   - Requires VMware PowerCLI v13.x
   - vSphere 7.0+
   - No credential caching
#>

# --- Config ---
$vcenter = 'vcenter.example.com'
$recentDeletionDays = 14
$defaultSnapshotAgeDays = 7

# --- Load PowerCLI ---
try {
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        throw "VMware PowerCLI is not installed or not on PSModulePath."
    }
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
} catch {
    Write-Host "ERROR: PowerCLI not available. $($_.Exception.Message)" -ForegroundColor Red
    exit
}

# --- Connect to vCenter ---
try {
    $cred = Get-Credential -Message "Enter vCenter credentials for $vcenter"
    Connect-VIServer -Server $vcenter -Credential $cred -ErrorAction Stop | Out-Null
} catch {
    Write-Host "Failed to connect: $($_.Exception.Message)" -ForegroundColor Red
    exit
}

# --- Functions ---
function Show-RecentDeletions {
    $since = (Get-Date).AddDays(-$recentDeletionDays)
    Get-VIEvent -Start $since -MaxSamples ([int]::MaxValue) |
        Where-Object { $_ -is [VMware.Vim.VmRemovedEvent] } |
        Sort-Object CreatedTime -Descending |
        Select-Object CreatedTime, UserName, FullFormattedMessage
}

function Show-VMs {
    Get-VM | Select-Object Name,
        @{N="OS";E={$_.Guest.OSFullName}},
        @{N="HWVersion";E={$_.ExtensionData.Config.Version}},
        @{N="Domain";E={ if ($_.Guest.HostName -and $_.Guest.HostName -like "*.*") { ($_.Guest.HostName -split '\.')[1..-1] -join '.' } else { $null } }},
        Notes
}

function Show-OldSnapshots {
    $threshold = (Get-Date).AddDays(-$defaultSnapshotAgeDays)
    Get-VM | Get-Snapshot | Where-Object { $_.Created -lt $threshold } |
        Select-Object VM, Name, Created, Description
}

function Show-NoTools {
    Get-VM | Where-Object { $_.ExtensionData.Summary.Guest.ToolsVersionStatus2 -eq "guestToolsNotInstalled" } |
        Select-Object Name, @{N="OS";E={$_.Guest.OSFullName}}, @{N="ToolsStatus";E={$_.ExtensionData.Summary.Guest.ToolsVersionStatus2}}
}

function Show-OutdatedTools {
    Get-VM | Where-Object { $_.ExtensionData.Summary.Guest.ToolsVersionStatus2 -eq "guestToolsNeedUpgrade" } |
        Select-Object Name, @{N="OS";E={$_.Guest.OSFullName}}, @{N="ToolsStatus";E={$_.ExtensionData.Summary.Guest.ToolsVersionStatus2}}
}

function Show-Compliance {
    if (-not (Get-Module -ListAvailable -Name VMware.VumAutomation)) {
        Write-Host "VMware.VumAutomation not available. Install PowerCLI VUM module." -ForegroundColor Yellow
        return
    }
    Import-Module VMware.VumAutomation -ErrorAction Stop
    $hosts = Get-VMHost
    Test-Compliance -Entity $hosts -UpdateType HostPatch | Out-Null
    Get-Compliance -Entity $hosts -Detailed |
        Select-Object Entity, Baseline, ComplianceStatus
}

function Remove-OldSnapshots {
    param(
        [int]$Days = $defaultSnapshotAgeDays,
        [int]$BatchSize = 2,
        [switch]$WhatIf
    )

    $threshold = (Get-Date).AddDays(-$Days)
    $snapshots = Get-VM | Get-Snapshot | Where-Object { $_.Created -lt $threshold }

    if (-not $snapshots) {
        Write-Host "No snapshots older than $Days days found."
        return
    }

    Write-Host "Found $($snapshots.Count) snapshots older than $Days days."
    $i = 0

    foreach ($group in ($snapshots | Sort-Object Created | ForEach-Object -Begin {$list=@()} -Process {
                $list += $_
                if ($list.Count -eq $BatchSize) { ,$list; $list=@() }
            } -End { if ($list.Count) { ,$list } })) {

        $i++
        Write-Host "=== Wave $i: processing $($group.Count) snapshot(s) ===" -ForegroundColor Cyan

        foreach ($sn in $group) {
            if ($WhatIf) {
                Write-Host "[DRY RUN] Would remove snapshot [$($sn.Name)] on VM [$($sn.VM)] (created $($sn.Created))"
            }
            else {
                Write-Host "Removing snapshot [$($sn.Name)] on VM [$($sn.VM)] (created $($sn.Created))"
                try {
                    $sn | Remove-Snapshot -Confirm:$false -RunAsync | Out-Null
                } catch {
                    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        if (-not $WhatIf) {
            do {
                $pending = Get-Task | Where-Object { $_.Name -eq 'RemoveSnapshot_Task' -and $_.State -eq 'Running' }
                if ($pending) {
                    Write-Host "Waiting for $($pending.Count) deletion task(s) to finish..."
                    Start-Sleep -Seconds 30
                }
            } while ($pending)
        }
    }

    Write-Host "All snapshots processed."
}

function Show-HotSwap {
    Get-VM | Select-Object Name,
        @{N='CPU_HotAdd';E={$_.ExtensionData.Config.CpuHotAddEnabled}},
        @{N='CPU_HotRemove';E={$_.ExtensionData.Config.CpuHotRemoveEnabled}},
        @{N='Memory_HotAdd';E={$_.ExtensionData.Config.MemoryHotAddEnabled}}
}

# --- Menu loop ---
do {
    Clear-Host
    Write-Host "=== vCenter VM Dashboard ==="
    Write-Host "1) Recent VM deletions (last $recentDeletionDays days)"
    Write-Host "2) List VMs (basic info)"
    Write-Host "3) Snapshots older than $defaultSnapshotAgeDays days"
    Write-Host "4) VMs without VMware Tools"
    Write-Host "5) VMs with outdated VMware Tools"
    Write-Host "6) Patch compliance (hosts)"
    Write-Host "7) Delete old snapshots (2 at a time)"
    Write-Host "8) Exit"
    Write-Host "9) List VMs with CPU/Memory Hot-Add or Hot-Remove enabled"
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Show-RecentDeletions | Format-Table -AutoSize; Pause }
        "2" { Show-VMs | Format-Table -AutoSize; Pause }
        "3" { Show-OldSnapshots | Format-Table -AutoSize; Pause }
        "4" { Show-NoTools | Format-Table -AutoSize; Pause }
        "5" { Show-OutdatedTools | Format-Table -AutoSize; Pause }
        "6" { Show-Compliance | Format-Table -AutoSize; Pause }
        "7" { 
            $confirm = Read-Host "Delete snapshots older than $defaultSnapshotAgeDays days (Y/N)?"
            if ($confirm -eq 'Y') { Remove-OldSnapshots -Days $defaultSnapshotAgeDays -BatchSize 2 }
            else { Write-Host "Aborted." }
            Pause
        }
        "8" { break }
        "9" { Show-HotSwap | Format-Table -AutoSize; Pause }
        default { Write-Host "Invalid option"; Start-Sleep 1 }
    }
} while ($true)

# --- Disconnect ---
Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false | Out-Null
