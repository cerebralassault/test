<#
ConfigMgr DP prereqs (minimal, MS-aligned)
- IIS + required IIS components
- RDC
No WDS / BranchCache / Dedup
PowerShell 5.1 required (auto-relaunch if running in pwsh)
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# If running under PowerShell 7+ (pwsh), relaunch in Windows PowerShell 5.1
if ($PSVersionTable.PSEdition -eq 'Core') {
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps51)) { throw "Windows PowerShell 5.1 not found at expected path: $ps51" }

    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Load-ServerManager {
    Import-Module ServerManager -ErrorAction Stop
    if (-not (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        throw "Install-WindowsFeature still not available. ServerManager module isn't usable on this system."
    }
}

function Install-Features {
    param([Parameter(Mandatory)][string[]]$Names)

    $missing = @()
    foreach ($name in $Names) {
        $f = Get-WindowsFeature -Name $name
        if (-not $f) { throw "Unknown Windows feature: $name" }
        if (-not $f.Installed) { $missing += $name }
    }

    if ($missing.Count -eq 0) {
        Write-Host "All required features already installed."
        return $false
    }

    Write-Host "Installing features: $($missing -join ', ')"
    $result = Install-WindowsFeature -Name $missing -IncludeManagementTools
    if (-not $result.Success) { throw "Feature installation failed." }

    return ($result.RestartNeeded -eq 'Yes')
}

function Start-ServiceIfPresent {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try { Start-Service -Name $Name -ErrorAction Stop } catch {}
    }
}

# -------- Execution --------
Assert-Admin
Load-ServerManager

$features = @(
    'Web-Server',        # IIS role
    'Web-ISAPI-Ext',     # ISAPI Extensions
    'Web-Windows-Auth',  # Windows Authentication
    'Web-Metabase',      # IIS 6 Metabase Compatibility
    'Web-WMI',           # IIS 6 WMI Compatibility
    'RDC'                # Remote Differential Compression
)

$restartNeeded = Install-Features -Names $features

Start-ServiceIfPresent -Name 'W3SVC'
Start-ServiceIfPresent -Name 'WAS'

if ($restartNeeded) {
    Write-Warning "A reboot is required to complete installation."
} else {
    Write-Host "DP prerequisites installed. No reboot required."
}
(Get-ComputerInfo).WindowsProductName
$PSVersionTable.PSVersion
$PSVersionTable.PSEdition
