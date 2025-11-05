# EPU/LA Sync Script with Restore Option

param(
    [ValidateSet('sync','restore')]
    [string]$Mode = 'sync',
    [switch]$NoPrompt
)

Import-Module ActiveDirectory -ErrorAction Stop

$SearchBaseOUDN = "<SET-THIS-OU-DN-LATER>"
$EPU_OU         = "OU=EPU,OU=Accounts,OU=Accounts and Groups,DC=DRE,DC=dev,DC=int"
$LA_OU          = "<SET-LA-OU-DN-LATER>"
$BackupRoot     = "C:\temp\OneID_Backups"
$OutputCsvPath  = Join-Path $BackupRoot ("EPU_LA_Sync_Backup_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmm"))

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

function Run-Sync {
    # Retrieve base and EPU/LA users
    $baseUsers = Get-ADUser -SearchBase $SearchBaseOUDN -LDAPFilter "(userPrincipalName=*)" -Properties SamAccountName,altSecurityIdentities
    $epuUsers  = Get-ADUser -SearchBase $EPU_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName
    $laUsers   = Get-ADUser -SearchBase $LA_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName

    # Create lookup for base user certs
    $lookup = @{}
    foreach ($u in $baseUsers) {
        $lookup[$u.SamAccountName.ToLower()] = $u.altSecurityIdentities
    }

    $backup = @()
    $suffixes = 'as','bso','cd','cm','co','cs','db','de','do','nit','no','so'
    $suffixPattern = '^epu(' + ($suffixes -join '|') + ')'

    # Sync EPU accounts
    foreach ($epu in $epuUsers) {
        if ($epu.SamAccountName -match $suffixPattern) {
            $suffix = $matches[1]
            $base = $epu.SamAccountName.Substring(3 + $suffix.Length)
            if ($lookup.ContainsKey($base.ToLower())) {
                $existing = @()
                if ($epu.altSecurityIdentities) {
                    $existing = $epu.altSecurityIdentities | Where-Object { $_ -notmatch 'Entrust|Homeland' }
                }
                $newAlt = $lookup[$base.ToLower()] | Where-Object { $_ -match 'Entrust|Homeland' }
                $merged = $existing + $newAlt | Select-Object -Unique
                if (-not ($epu.altSecurityIdentities -join '|') -eq ($merged -join '|')) {
                    Set-ADUser -Identity $epu.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
                }
                $backup += [pscustomobject]@{
                    SamAccountName = $epu.SamAccountName
                    BaseAccount    = $base
                    AltSecurityIdentities = ($epu.altSecurityIdentities -join '|')
                    NewAltSecID    = ($merged -join '|')
                    DistinguishedName = $epu.DistinguishedName
                }
            }
        }
    }

    # Sync LA accounts
    foreach ($la in $laUsers) {
        if ($la.SamAccountName.StartsWith("LA")) {
            $base = $la.SamAccountName.Substring(2)
            if ($lookup.ContainsKey($base.ToLower())) {
                $existing = @()
                if ($la.altSecurityIdentities) {
                    $existing = $la.altSecurityIdentities | Where-Object { $_ -notmatch 'Entrust|Homeland' }
                }
                $newAlt = $lookup[$base.ToLower()] | Where-Object { $_ -match 'Entrust|Homeland' }
                $merged = $existing + $newAlt | Select-Object -Unique
                if (-not ($la.altSecurityIdentities -join '|') -eq ($merged -join '|')) {
                    Set-ADUser -Identity $la.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
                }
                $backup += [pscustomobject]@{
                    SamAccountName = $la.SamAccountName
                    BaseAccount    = $base
                    AltSecurityIdentities = ($la.altSecurityIdentities -join '|')
                    NewAltSecID    = ($merged -join '|')
                    DistinguishedName = $la.DistinguishedName
                }
            }
        }
    }

    # Save backup
    $backup | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

    if (-not $NoPrompt) {
        Write-Host "Backup saved to $OutputCsvPath"
        Read-Host "Press Enter to finish"
    }
}

function Run-Restore {
    # Select and restore from a backup CSV
    $files = Get-ChildItem -Path $BackupRoot -Filter "EPU_LA_Sync_Backup_*.csv" -File | Sort-Object LastWriteTime -Descending
    if (!$files) { Write-Host "No backup files found."; return }

    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $files[$i].Name)
    }
    $sel = Read-Host "Select a backup file by number"
    if ($sel -notmatch '^[1-9]\d*$' -or [int]$sel -gt $files.Count) { return }

    $selectedPath = $files[[int]$sel - 1].FullName
    $rows = Import-Csv -Path $selectedPath
    foreach ($r in $rows) {
        try {
            $dn = $r.DistinguishedName
            if (-not $dn) { continue }
            $vals = if ($r.NewAltSecID) { $r.NewAltSecID -split '\|' } else { @() }
            if ($vals.Count -gt 0) {
                Set-ADUser -Identity $dn -Replace @{ altSecurityIdentities = $vals }
            } else {
                Set-ADUser -Identity $dn -Clear altSecurityIdentities
            }
        } catch {}
    }
}

switch ($Mode) {
    'sync'    { Run-Sync }
    'restore' { Run-Restore }
    default   { Write-Error "Invalid mode. Use 'sync' or 'restore'." }
}
