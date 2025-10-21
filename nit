if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

function Connect-LDAPSServer {
    param($Server, $Port, $BaseDN, $Username, $PSCR_Path)
    $key = (1..32)
    if (!(Test-Path $PSCR_Path)) {
        $cred = Get-Credential -Message "Enter ONEID credentials"
        $cred.Password | ConvertFrom-SecureString -Key $key | Set-Content -Path $PSCR_Path -Force
    }
    $secure = Get-Content $PSCR_Path | ConvertTo-SecureString -Key $key
    $creds = New-Object System.Management.Automation.PSCredential($Username, $secure)
    $pwd = $creds.GetNetworkCredential().Password
    $conn = New-Object System.DirectoryServices.Protocols.LdapConnection("$Server`:$Port")
    $conn.SessionOptions.SecureSocketLayer = $true
    $conn.SessionOptions.VerifyServerCertificate = { $true }
    $conn.SessionOptions.ProtocolVersion = 3
    $conn.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
    $conn.Bind((New-Object System.Net.NetworkCredential($Username, $pwd)))
    return $conn
}

function Get-LDAPSQuery {
    param($LDAPS_Connection, $BaseDN, $LDAPS_Filter)
    $req = New-Object System.DirectoryServices.Protocols.SearchRequest($BaseDN, $LDAPS_Filter, [System.DirectoryServices.Protocols.SearchScope]::Subtree)
    try { return $LDAPS_Connection.SendRequest($req) } catch { return $null }
}

function Get-OneIdIssuerSerial {
    param($Entry)
    $bin = $Entry.Attributes."hspd12currentpivauthenticationcertificate;binary"
    if (-not $bin) { return $null }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($bin)
        $issuerParts = $cert.IssuerName.Name -split "," | ForEach-Object { $_.Trim() }
        [array]::Reverse($issuerParts)
        $issuer = ($issuerParts -join ",")
        $serial = [System.BitConverter]::ToString($cert.GetSerialNumber()) -replace "-", ""
        [pscustomobject]@{ IssuerName = $issuer; SerialNumber = $serial }
    } catch {
        return $null
    }
}

function Run-OneIdUpdateMode {
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
    $doWhatIf = (Read-Host "Run What-If mode (Y/N)") -match '^(Y|y)$'
    $confirm = Read-Host "Update all matched users (Y/N)"
    if ($confirm -notmatch '^(Y|y)$') { return }

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
}

function Run-RestoreMode {
    $files = Get-ChildItem -Path $BackupRoot -Filter "OneID_AltSecIds_Backup_*.csv" -File | Sort-Object LastWriteTime -Descending
    if (!$files) { return }
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}) {1} ({2})" -f ($i + 1), $files[$i].Name, $files[$i].LastWriteTime)
    }
    $sel = Read-Host "Select a backup by number"
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $files.Count) { return }
    $path = $files[[int]$sel - 1].FullName
    $doWhatIf = (Read-Host "Run restore in What-If mode (Y/N)") -match '^(Y|y)$'
    $confirm = Read-Host "Restore ALL users from this backup (Y/N)"
    if ($confirm -notmatch '^(Y|y)$') { return }

    $rows = Import-Csv -Path $path
    foreach ($r in $rows) {
        try {
            $dn = $r.DistinguishedName
            if (-not $dn) { continue }
            $vals = if ($r.AltSecurityIdentities) { $r.AltSecurityIdentities -split '\|' } else { @() }
            if ($doWhatIf) {
                if ($vals.Count -gt 0) {
                    Set-ADUser -Identity $dn -Replace @{ altSecurityIdentities = $vals } -WhatIf
                } else {
                    Set-ADUser -Identity $dn -Clear altSecurityIdentities -WhatIf
                }
            } else {
                if ($vals.Count -gt 0) {
                    Set-ADUser -Identity $dn -Replace @{ altSecurityIdentities = $vals }
                } else {
                    Set-ADUser -Identity $dn -Clear altSecurityIdentities
                }
            }
        } catch {}
    }
}

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
}

$mode = Read-Host "Select mode: 1 = Update from OneID, 2 = Restore from backup, 3 = Sync EPU from base users (no OneID call)"
if ($mode -eq '1') { Run-OneIdUpdateMode }
elif ($mode -eq '2') { Run-RestoreMode }
elif ($mode -eq '3') { Run-EpuSyncFromBaseMode }
