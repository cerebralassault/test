param(
    [ValidateSet('update', 'restore')]
    [string]$Mode,
    [switch]$NoPrompt
)

Add-Type -AssemblyName "System.DirectoryServices.Protocols"
Import-Module ActiveDirectory -ErrorAction Stop

# Configuration
$BackupRoot       = "C:\temp\OneID_Backups"
$SearchBaseOUDN   = "<SET-THIS-OU-DN-LATER>"
$OutputCsvPath    = Join-Path $BackupRoot ("OneID_MainAccount_Backup_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmm"))
$Port             = 636
$ServerName       = <insertlater>
$BaseDN           = <insertlater>
$ONEID_CREDS_DN   = <insertlater>
$ONEID_Creds_Path = "$BackupRoot\oneid_auth.txt"

# Ensure backup directory exists
if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

# Connect securely to OneID via LDAPS
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

# Perform LDAPS query
function Get-LDAPSQuery {
    param($LDAPS_Connection, $BaseDN, $LDAPS_Filter)
    $req = New-Object System.DirectoryServices.Protocols.SearchRequest($BaseDN, $LDAPS_Filter, [System.DirectoryServices.Protocols.SearchScope]::Subtree)
    try { return $LDAPS_Connection.SendRequest($req) } catch { return $null }
}

# Extract Issuer + SerialNumber from OneID certificate
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
    } catch { return $null }
}

# --- MAIN UPDATE MODE ---
function Run-UpdateMainAccounts {
    $users = Get-ADUser -SearchBase $SearchBaseOUDN -SearchScope Subtree -LDAPFilter "(userPrincipalName=*)" -Properties SamAccountName,UserPrincipalName,altSecurityIdentities
    $ONEID = Connect-LDAPSServer -Server $ServerName -Port $Port -BaseDN $BaseDN -Username $ONEID_CREDS_DN -PSCR_Path $ONEID_Creds_Path

    # Build backup data
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

    # Export backup
    $Backup | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

    if (-not $NoPrompt) {
        $confirm = Read-Host "Update all matched users (Y/N)"
        if ($confirm -notmatch '^(Y|y)$') { return }
    }

    # Update accounts only when needed
    foreach ($t in $Backup | Where-Object { $_.MatchState -eq "MatchedWithPIV" -and $_.NewAltSecID }) {
        try {
            # Preserve non-Entrust/Homeland entries
            $existing = @()
            if ($t.AltSecurityIdentities) {
                $existing = $t.AltSecurityIdentities -split '\|' | Where-Object { $_ -notmatch 'Entrust|Homeland' }
            }
            # Merge and normalize arrays
            $merged = $existing + $t.NewAltSecID | Select-Object -Unique
            $current = @($t.AltSecurityIdentities -split '\|') | Sort-Object
            $new     = @($merged) | Sort-Object

            # Compare sorted lists; update only if real change
            if (-not (($current -join '|') -eq ($new -join '|'))) {
                Write-Host "Updating $($t.Username)..."
                Set-ADUser -Identity $t.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
            }
        } catch {}
    }
}

# --- RESTORE MODE ---
function Run-RestoreFromBackup {
    $files = Get-ChildItem -Path $BackupRoot -Filter "OneID_MainAccount_Backup_*.csv" -File | Sort-Object LastWriteTime -Descending
    if (!$files) { Write-Host "No backups found."; return }
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0}) {1} ({2})" -f ($i + 1), $files[$i].Name, $files[$i].LastWriteTime)
    }
    $sel = Read-Host "Select a backup by number"
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $files.Count) { return }
    $path = $files[[int]$sel - 1].FullName
    $rows = Import-Csv -Path $path
    foreach ($r in $rows) {
        try {
            $dn = $r.DistinguishedName
            if (-not $dn) { continue }
            $vals = if ($r.AltSecurityIdentities) { $r.AltSecurityIdentities -split '\|' } else { @() }
            if ($vals.Count -gt 0) {
                Write-Host "Restoring $($r.Username)..."
                Set-ADUser -Identity $dn -Replace @{ altSecurityIdentities = $vals }
            } else {
                Write-Host "Clearing $($r.Username)..."
                Set-ADUser -Identity $dn -Clear altSecurityIdentities
            }
        } catch {}
    }
}

# --- Mode selection ---
switch ($Mode) {
    'update'  { Run-UpdateMainAccounts }
    'restore' { Run-RestoreFromBackup }
    default   { Write-Error "Invalid mode. Use 'update' or 'restore'." }
}
