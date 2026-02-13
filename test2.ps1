<#
ConfigMgr DP Prereqs (Server 2025 safe)
Uses DISM instead of Install-WindowsFeature
Run elevated
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

function Enable-Feature {
    param([Parameter(Mandatory)][string]$Name)

    $state = dism /online /get-featureinfo /featurename:$Name 2>$null
    if ($state -match "State : Enabled") {
        Write-Host "Already enabled: $Name"
        return
    }

    Write-Host "Enabling: $Name"
    dism /online /enable-feature /featurename:$Name /all /norestart | Out-Null
}

Assert-Admin

$features = @(
    'IIS-WebServerRole',
    'IIS-WebServer',
    'IIS-ISAPIExtensions',
    'IIS-WindowsAuthentication',
    'IIS-Metabase',
    'IIS-WMICompatibility',
    'RDC'
)

foreach ($f in $features) {
    Enable-Feature -Name $f
}

# Start IIS services if present
foreach ($svc in @('W3SVC','WAS')) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') {
        Start-Service $svc
    }
}

Write-Warning "If features were newly installed, reboot before installing the DP role."
