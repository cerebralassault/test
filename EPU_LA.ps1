param(
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

$baseUsers = Get-ADUser -SearchBase $SearchBaseOUDN -LDAPFilter "(userPrincipalName=*)" -Properties SamAccountName,altSecurityIdentities
$epuUsers  = Get-ADUser -SearchBase $EPU_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName
$laUsers   = Get-ADUser -SearchBase $LA_OU -Filter * -Properties SamAccountName,altSecurityIdentities,DistinguishedName

$lookup = @{}
foreach ($u in $baseUsers) {
    $lookup[$u.SamAccountName.ToLower()] = $u.altSecurityIdentities
}

$backup = @()

$suffixes = 'as','bso','cd','cm','co','cs','db','de','do','nit','no','so'
$suffixPattern = '^epu(' + ($suffixes -join '|') + ')'

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
            $backup += [pscustomobject]@{
                SamAccountName = $epu.SamAccountName
                BaseAccount    = $base
                AltSecurityIdentities = ($epu.altSecurityIdentities -join '|')
                NewAltSecID    = ($merged -join '|')
                DistinguishedName = $epu.DistinguishedName
            }
            Set-ADUser -Identity $epu.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
        }
    }
}

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
            $backup += [pscustomobject]@{
                SamAccountName = $la.SamAccountName
                BaseAccount    = $base
                AltSecurityIdentities = ($la.altSecurityIdentities -join '|')
                NewAltSecID    = ($merged -join '|')
                DistinguishedName = $la.DistinguishedName
            }
            Set-ADUser -Identity $la.DistinguishedName -Replace @{ altSecurityIdentities = $merged }
        }
    }
}

$backup | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

if (-not $NoPrompt) {
    Write-Host "Backup saved to $OutputCsvPath"
    Read-Host "Press Enter to finish"
}
