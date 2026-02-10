<#
ConfigMgr Distribution Point prerequisite installer (minimal, MS-aligned)
Windows Server + PowerShell 5.1
Runs immediately with no parameters

Installs:
 - IIS (with required subfeatures for ConfigMgr DP)
 - RDC

Leaves out:
 - WDS / BranchCache / Dedup
 - BITS IIS Server Extension (not required for DP)
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Assert-WindowsServer {
    if (-not (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        throw "Install-WindowsFeature not found. This script is for Windows Server only."
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

    # RestartNeeded is typically "Yes"/"No" (string)
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
Assert-WindowsServer

# Minimal DP prerequisites (IIS + required IIS components + RDC)
$features = @(
    'Web-Server',        # IIS role
    'Web-ISAPI-Ext',     # ISAPI Extensions
    'Web-Windows-Auth',  # Windows Authentication
    'Web-Metabase',      # IIS 6 Metabase Compatibility
    'Web-WMI',           # IIS 6 WMI Compatibility
    'RDC'                # Remote Differential Compression
)

$restartNeeded = Install-Features -Names $features

# Best-effort: start common services after role installation
Start-ServiceIfPresent -Name 'W3SVC'     # IIS
Start-ServiceIfPresent -Name 'WAS'       # Windows Process Activation Service (usually already running)

if ($restartNeeded) {
    Write-Warning "A reboot is required to complete installation."
} else {
    Write-Host "DP prerequisites installed. No reboot required."
}
