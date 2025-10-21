# OneID altSecurityIdentities Synchronization & Restore Tool
# PowerShell 5.1 | Domain-joined Windows Server environment

Add-Type -AssemblyName "System.DirectoryServices.Protocols"
Import-Module ActiveDirectory -ErrorAction Stop

# Configuration
$BackupRoot       = "C:\temp\OneID_Backups"
$SearchBaseOUDN   = "<SET-THIS-OU-DN-LATER>"
$EPU_OU           = "OU=EPU,OU=Accounts,OU=Accounts and Groups,DC=DRE,DC=dev,DC=int"
$OutputCsvPath    = Join-Path $BackupRoot ("OneID_AltSecIds_Backup_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmm"))
$Port             = 636
$ServerName       = <insertlater>
$BaseDN           = <insertlater>
$ONEID_CREDS_DN   = <insertlater>
$ONEID_Creds_Path = "$BackupRoot\oneid_auth.txt"

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

function Connect-LDAPSServer {
    param(
        [string]$Server,
        [int]$Port,
        [string]$BaseDN,
        [string]$Username,
        [string]$PSCR_Path
    )

    $key = (1..32)
    if (!(Test-Path $PSCR_Path)) {
        $cred = Get-Credential -Message "Enter ONEID credentials for $Username"
        $cred.Password | ConvertFrom-SecureString -Key $key | Set-Content -Path $PSCR_Path -Force
    }

    $secure = Get-Content $PSCR_Path | ConvertTo-SecureString -Key $key
    $creds  = New-Object System.Management.Automation.PSCredential($Username, $secure)
    $pwd    = $creds.GetNetworkCredential().Password

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

function Run-UpdateMode {
    $filterByDept = Read-Host "Do you want to filter by department Y or N"

    if ($filterByDept -match '^(Y|y)$') {
        $Department = Read-Host "Enter the department name to include exact match as in AD or * for all with department set"
        if ($Department -eq "*") {
            $ldapFilter = "(&(userPrincipalName=*)(department=*))"
        } else {
            $ldapFilter = "(&(userPrincipalName=*)(department=$Department))"
        }
    } else {
        $ldapFilter = "(userPrincipalName=*)"
    }

    $users = Get-ADUser -SearchBase $SearchBaseOUDN -SearchScope Subtree `
        -LDAPFilter $ldapFilter `
        -Properties SamAccountName,UserPrincipalName,altSecurityIdentities,Department

    $ONEID = Connect-LDAPSServer -Server $ServerName -Port $Port -BaseDN $BaseDN -Username $ONEID_CREDS_DN -PSCR_Path $ONEID_Creds_Path

    $userUpdates = @{}
    $Backup = foreach ($u in $users) {
        $filter = "(&(objectClass=*)(hspd12upn=$($u.UserPrincipalName)))"
        $resp = Get-LDAPSQuery -LDAPS_Connection $ONEID -BaseDN $BaseDN -LDAPS_Filter $filter
        $issuer=$null; $serial=$null; $newAlt=$null; $match="NoMatch"

        if ($resp -and $resp.Entries.Count -eq 1) {
            $pair = Get-OneIdIssuerSerial -Entry $resp.Entries[0]
            if ($pair) {
                $issuer=$pair.IssuerName; $serial=$pair.SerialNumber
                $newAlt="X509:<I>$issuer<SR>$serial"
                $match="MatchedWithPIV"
                $userUpdates[$u.SamAccountName] = $newAlt
            }
        } elseif ($resp -and $resp.Entries.Count -gt 1) { $match="Ambiguous" }

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

    $ans1 = Read-Host "Proceed to update phase Y or N"
    if ($ans1 -notmatch '^(Y|y)$') { return }

    $doWhatIf = (Read-Host "Run this update in What-If simulation mode Y or N") -match '^(Y|y)$'
    $confirmAll = Read-Host "Proceed to update all matched users Y or N"
    if ($confirmAll -notmatch '^(Y|y)$') { return }

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
        $base = $epu.SamAccountName -replace '^epu(?:as|bso|cd|cm|co|cs|db|de|do|nit|no|so)', ''
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

    for ($i=0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}) {1} ({2})" -f ($i+1), $files[$i].Name, $files[$i].LastWriteTime)
    }
    $sel = Read-Host "Select a backup by number"
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $files.Count) { return }
    $path = $files[[int]$sel - 1].FullName

    $doWhatIf = (Read-Host "Run restore in What-If mode Y or N") -match '^(Y|y)$'
    $confirm = Read-Host "Restore ALL users from this backup Y or N"
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

$restore = Read-Host "Do you want to restore from a previous backup Y or N"
if ($restore -match '^(Y|y)$') { Run-RestoreMode } else { Run-UpdateMode }
