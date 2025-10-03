# vCenter VM Dashboard

This dashboard script is packaged as a hybrid CMD + PowerShell file.  
That means you can double-click it in Explorer, run it from `cmd.exe`, or call the `.ps1` directly in PowerShell.  
When it starts, it shows a numbered menu.

---

## Requirements

- vCenter 7.0 or later  
- VMware PowerCLI 13.x  
- Windows PowerShell 5.1 or PowerShell 7+  
- A vCenter account with at least read-only access  

---

## Launching

From Explorer:  
- Double-click `VC_Dashboard.cmd`  

From CMD:

```cmd
VC_Dashboard.cmd
```

From PowerShell:

```powershell
.\VC_Dashboard.ps1
```

The CMD wrapper takes care of execution policy and cleans up temp files after the run.

---

## Menu Options

### Option 1 – Recent VM Deletions

Pulls vCenter events for the last 14 days (default) and shows which VMs were deleted, when, and by whom.

```powershell
$since = (Get-Date).AddDays(-14)
Get-VIEvent -Start $since -MaxSamples ([int]::MaxValue) |
    Where-Object { $_ -is [VMware.Vim.VmRemovedEvent] } |
    Sort-Object CreatedTime -Descending |
    Select-Object CreatedTime, UserName, FullFormattedMessage
```

Example output:

```
CreatedTime          UserName       FullFormattedMessage
-----------          --------       --------------------
10/02/2025 14:32     ADMIN\jsmith   VM 'TestVM01' was removed
09/29/2025 09:17     ADMIN\svc_vm   Automation task removed VM 'LegacyVM'
```

---

### Option 2 – List VMs (basic info)

Lists VM Name, Guest OS, Hardware Version, Domain, and Notes.

```powershell
Get-VM | Select-Object Name,
    @{N="OS";E={$_.Guest.OSFullName}},
    @{N="HWVersion";E={$_.ExtensionData.Config.Version}},
    @{N="Domain";E={ if ($_.Guest.HostName -and $_.Guest.HostName -like "*.*") { ($_.Guest.HostName -split '\.')[1..-1] -join '.' } else { $null } }},
    Notes
```

---

### Option 3 – Snapshots older than N days

Lists snapshots older than the configured threshold (default 7 days).

```powershell
$threshold = (Get-Date).AddDays(-7)
Get-VM | Get-Snapshot -VM $_ | Where-Object { $_.Created -lt $threshold } |
    Select-Object VM, Name, Created, Description
```

---

### Option 4 – VMs without VMware Tools

Lists VMs that don’t have VMware Tools installed.

```powershell
Get-VM | Where-Object { $_.ExtensionData.Summary.Guest.ToolsVersionStatus2 -eq "guestToolsNotInstalled" } |
    Select-Object Name, @{N="OS";E={$_.Guest.OSFullName}}, @{N="ToolsStatus";E={$_.ExtensionData.Summary.Guest.ToolsVersionStatus2}}
```

---

### Option 5 – VMs with outdated VMware Tools

Lists VMs where Tools are installed but outdated.

```powershell
Get-VM | Where-Object { $_.ExtensionData.Summary.Guest.ToolsVersionStatus2 -eq "guestToolsNeedUpgrade" } |
    Select-Object Name, @{N="OS";E={$_.Guest.OSFullName}}, @{N="ToolsStatus";E={$_.ExtensionData.Summary.Guest.ToolsVersionStatus2}}
```

---

### Option 6 – Patch compliance (hosts)

Runs a compliance check on ESXi hosts with Lifecycle Manager.

```powershell
Import-Module VMware.VumAutomation -ErrorAction Stop
$hosts = Get-VMHost
Test-Compliance -Entity $hosts -UpdateType HostPatch | Out-Null
Get-Compliance -Entity $hosts -Detailed |
    Select-Object Entity, Baseline, ComplianceStatus
```

---

### Option 7 – Delete old snapshots (2 at a time)

Deletes snapshots older than N days in batches of 2. Uses `-RunAsync` and waits until the previous batch finishes.

```powershell
$threshold = (Get-Date).AddDays(-7)
$snapshots = Get-VM | Get-Snapshot | Where-Object { $_.Created -lt $threshold }

foreach ($sn in $snapshots) {
    Remove-Snapshot -Snapshot $sn -Confirm:$false -RunAsync
    do {
        $pending = Get-Task | Where-Object { $_.Name -eq 'RemoveSnapshot_Task' -and $_.State -eq 'Running' }
        if ($pending) { Start-Sleep -Seconds 30 }
    } while ($pending)
}
```

---

### Option 8 – Exit

Disconnects from vCenter and exits the script.

```powershell
Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false
```

---

### Option 9 – VMs with Hot-Add/Hot-Remove enabled

Shows whether CPU/Memory hot-add or hot-remove is enabled.

```powershell
Get-VM | Select-Object Name,
    @{N='CPU_HotAdd';E={$_.ExtensionData.Config.CpuHotAddEnabled}},
    @{N='CPU_HotRemove';E={$_.ExtensionData.Config.CpuHotRemoveEnabled}},
    @{N='Memory_HotAdd';E={$_.ExtensionData.Config.MemoryHotAddEnabled}}
```

---

## Notes

- Snapshots: test deletions carefully. Removing large snapshots can generate heavy I/O.  
- Compliance checks: requires Lifecycle Manager (LCM/VUM) module.  
- CSV exports: functions output objects, so you can pipe to `Export-Csv` if you run the `.ps1` directly.  
- Compatible with both Windows PowerShell 5.1 and PowerShell 7.  

---

## Example Menu

```
=== vCenter VM Dashboard ===
1) Recent VM deletions (last 14 days)
2) List VMs (basic info)
3) Snapshots older than 7 days
4) VMs without VMware Tools
5) VMs with outdated VMware Tools
6) Patch compliance (hosts)
7) Delete old snapshots (2 at a time)
8) Exit
9) List VMs with CPU/Memory Hot-Add or Hot-Remove enabled
Select option:
```
