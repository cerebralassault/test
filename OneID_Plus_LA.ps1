param(
    [ValidateSet('1','2','3')]
    [string]$Mode,
    [string]$Department,
    [switch]$NoPrompt
)

Add-Type -AssemblyName "System.DirectoryServices.Protocols"
Import-Module ActiveDirectory -ErrorAction Stop

# Configuration
$BackupRoot       = "C:\temp\OneID_Backups"
$SearchBaseOUDN   = "<SET-THIS-OU-DN-LATER>"
$EPU_OU           = "OU=EPU,OU=Accounts,OU=Accounts and Groups,DC=DRE,DC=dev,DC=int"
$LA_OU            = "<SET-LA-OU-DN-LATER>"   # <- LA accounts OU
$OutputCsvPath    = Join-Path $BackupRoot ("OneID_AltSecIds_Backup_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmm"))
$Port             = 636
$ServerName       = <insertlater>
$BaseDN           = <insertlater>
$ONEID_CREDS_DN   = <insertlater>
$ONEID_Creds_Path = "$BackupRoot\oneid_auth.txt"

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

# ... [functions unchanged: Connect-LDAPSServer, Get-LDAPSQuery, Get-OneIdIssuerSerial] ...

function Run-OneIdUpdateMode {
    param(
        [string]$Department,
        [switch]$NoPrompt
    )

    if ($NoPrompt) {
        if ($Department) {
            $ldapFilter = "(&(userPrincipalName=*)(department=$Department))"
        } else {
            $ldapFilter = "(userPrincipalName=*)"
        }
    } else {
        $filterByDept = Read-Host "Do you want to filter by department (Y/N)"
        if ($filterByDept -match '^(Y|y)$') {
            $Department = Read-Host "Enter department name or * for all with department set"
            if ($Department -eq "*") {
                $ldapFilter = "(&(userPrincipalName=*)(department=*))"
            } else {
                $ldapFilter = "(&(userPrincipalName=*)(department=$Department))"
            }
        } else {
            $ldapFilter = "(userPrincipalName=*)"
        }
    }

    $users = Get-ADUser -SearchBase $SearchBaseOUDN -SearchScope Subtree -LDAPFilter $ldapFilter -Properties SamAccountName,UserPrincipalName,altSecurityIdentities,Department
    $ONEID = Connect-LDAPSServer -Server $ServerName -Port $Port -BaseDN $BaseDN -Username $ONEID_CREDS_DN -PSCR_Path $ONEID_Creds_Path
    $userUpdates = @{}
    $Backup = foreach ($u in $users) {
        $filter = "(&(objectClass=*)(hspd12upn=$($u.UserPrincipalName)))"
        $resp = Get-LDAPSQuery -LDAPS_Connection $ONEID -BaseDN $BaseDN -LDAPS_Filter $filter
        $issuer = $serial = $newAlt = $null
        $match = "NoMatch"
        if ($resp -and $resp.Entries.Count -eq 1) {
            $pair = Get-OneIdIssuerSerial -Entry $resp.Entries[0]
            if ($pair) {
                $issuer = $pair.IssuerName
                $serial = $pair.SerialNumber
                $newAlt = "X509:<I>$issuer<SR>$serial"
                $match = "MatchedWithPIV"
                $userUpdates[$u.SamAccountName] = $newAlt
            }
        } elseif ($resp -and $resp.Entries.Count -gt 1) { $match = "Ambiguous" }
        [pscustomobject]@{
            Username=$u.SamAccountName
            UPN=$u.UserPrincipalName
            Issuer=$issuer
            SerialNumber=$serial
            AltSecurityIdentities=($u.altSecurityIdentities -join "|")
            MatchState=$match
            NewAltSecID=$newAlt
            DistinguishedName=$u.DistinguishedName
        }
    }
    $Backup | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    $doWhatIf = if ($NoPrompt) { $false } else { (Read-Host "Run What-If mode (Y/N)") -match '^(Y|y)$' }
    $confirm = if ($NoPrompt) { $true } else { Read-Host "Update all matched users (Y/N)" }
    if ($confirm -is [string] -and $confirm -notmatch '^(Y|y)$') { return }

    foreach ($t in $Backup | Where-Object { $_.MatchState -eq "MatchedWithPIV" -and $_.NewAltSecID }) {
        try {
            $existing = @()
            if ($t.AltSecurityIdentities) {
                $existing = $t.AltSecurityIdentities -split '\|' | Where-Object { $_ -notmatch 'Entrust|Homeland' }
            }
            $merged = $existing + $t.NewAltSecID | Select-Object -Unique
            if ($doWhatIf) {
                Set-ADUser -Identity $t.DistinguishedName -Replace @{ altSecurityIdentities = $merged } -WhatIf
            } else {
                Set-ADUser -Identity $t.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
            }
        } catch {}
    }

    # --- EPU Sync Section ---
    $epuUsers = Get-ADUser -SearchBase $EPU_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName
    foreach ($epu in $epuUsers) {
        $base = $epu.SamAccountName -replace '^epu[a-z]{1,4}', ''
        if ($userUpdates.ContainsKey($base)) {
            $newAlt = $userUpdates[$base]
            $existing = @()
            if ($epu.altSecurityIdentities) {
                $existing = $epu.altSecurityIdentities | Where-Object { $_ -notmatch 'Entrust|Homeland' }
            }
            $merged = $existing + $newAlt | Select-Object -Unique
            if ($doWhatIf) {
                Set-ADUser -Identity $epu.DistinguishedName -Replace @{ altSecurityIdentities = $merged } -WhatIf
            } else {
                Set-ADUser -Identity $epu.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
            }
        }
    }

    # --- LA Sync Section ---
    $laUsers = Get-ADUser -SearchBase $LA_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName
    foreach ($la in $laUsers) {
        $base = $la.SamAccountName -replace '^LA', ''
        if ($userUpdates.ContainsKey($base)) {
            $newAlt = $userUpdates[$base]
            $existing = @()
            if ($la.altSecurityIdentities) {
                $existing = $la.altSecurityIdentities | Where-Object { $_ -notmatch 'Entrust|Homeland' }
            }
            $merged = $existing + $newAlt | Select-Object -Unique
            if ($doWhatIf) {
                Set-ADUser -Identity $la.DistinguishedName -Replace @{ altSecurityIdentities = $merged } -WhatIf
            } else {
                Set-ADUser -Identity $la.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
            }
        }
    }
}

# ... [Run-RestoreMode unchanged] ...

function Run-EpuSyncFromBaseMode {
    $baseUsers = Get-ADUser -SearchBase $SearchBaseOUDN -LDAPFilter "(userPrincipalName=*)" -Properties SamAccountName,altSecurityIdentities
    $epuUsers = Get-ADUser -SearchBase $EPU_OU -Filter * -Properties SamAccountName,altSecurityIdentities
    $suffixes = 'as','bso','cd','cm','co','cs','db','de','do','nit','no','so'
    $suffixPattern = '^epu(' + ($suffixes -join '|') + ')'
    $lookup = @{}
    foreach ($u in $baseUsers) { $lookup[$u.SamAccountName.ToLower()] = $u.altSecurityIdentities }
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
                Write-Host "Syncing $($epu.SamAccountName) from base $base"
                Set-ADUser -Identity $epu.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
            }
        }
    }

    # --- LA Sync from Base Section ---
    $laUsers = Get-ADUser -SearchBase $LA_OU -Filter * -Properties SamAccountName,altSecurityIdentities
    foreach ($la in $laUsers) {
        $base = $la.SamAccountName -replace '^LA', ''
        if ($lookup.ContainsKey($base.ToLower())) {
            $existing = @()
            if ($la.altSecurityIdentities) {
                $existing = $la.altSecurityIdentities | Where-Object { $_ -notmatch 'Entrust|Homeland' }
            }
            $newAlt = $lookup[$base.ToLower()] | Where-Object { $_ -match 'Entrust|Homeland' }
            $merged = $existing + $newAlt | Select-Object -Unique
            Write-Host "Syncing $($la.SamAccountName) from base $base"
            Set-ADUser -Identity $la.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
        }
    }
}

switch ($Mode) {
    '1' { Run-OneIdUpdateMode -Department $Department -NoPrompt:$NoPrompt }
    '2' { Run-RestoreMode }
    '3' { Run-EpuSyncFromBaseMode }
    default { Write-Error "Invalid mode selected. Use -Mode 1, 2, or 3." }
}
