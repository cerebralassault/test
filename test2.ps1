#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-DismFeatureEnabled {
    param([Parameter(Mandatory)][string]$Name)

    $out = & dism.exe /online /get-featureinfo /featurename:$Name 2>&1
    if ($LASTEXITCODE -ne 0) { throw "DISM failed querying feature '$Name': $out" }
    return ($out -match 'State\s*:\s*Enabled')
}

function Enable-DismFeatureIfMissing {
    param([Parameter(Mandatory)][string]$Name)

    if (Test-DismFeatureEnabled -Name $Name) {
        Write-Host "OK (already enabled): $Name"
        return
    }

    Write-Host "Enabling: $Name"
    $out = & dism.exe /online /enable-feature /featurename:$Name /all /norestart 2>&1
    if ($LASTEXITCODE -ne 0) { throw "DISM failed enabling feature '$Name': $out" }
}

# --- Add the DP-specific pieces you likely DON'T already have ---

# Required for Distribution Point (RDC)
Enable-DismFeatureIfMissing -Name "RDC"

# Usually already present with your IIS script, but harmless to ensure:
Enable-DismFeatureIfMissing -Name "BITS"

# --- IIS request filtering tweak: allow PROPFIND (DP needs it) ---
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
if (Test-Path $appcmd) {
    # Ensure Request Filtering feature exists (name differs between feature vs IIS section;
    # if your prior script installed it, this will just be a no-op config add)
    & $appcmd set config -section:system.webServer/security/requestFiltering /+verbs.[verb='PROPFIND',allowed='True'] /commit:apphost | Out-Null
    Write-Host "OK: ensured PROPFIND is allowed in IIS requestFiltering."
} else {
    Write-Warning "appcmd.exe not found. IIS may not be installed where expected."
}

Write-Host "Done. Reboot only if DISM indicates one is pending."
