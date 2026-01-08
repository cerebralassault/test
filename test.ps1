<#
PowerShell 5.1
Input file contains computer FQDNs (hostname.domain.tld).
Prompts once per unique domain in the file for credentials.
Queries the matching domain only. Marks unreachable domains and skips them.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$ServerListPath,

    [string]$OutputCsv = (Join-Path $PWD ("AD_ServerAttributes_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")))
)

Import-Module ActiveDirectory -ErrorAction Stop

$attrs = @(
    "objectOwnercodeGSS",
    "objectOwnercodeISO",
    "objectOwnerDesignees",
    "objectOwners"
)

# Read FQDNs (ignore blanks and comment lines)
$servers = Get-Content -Path $ServerListPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

# Build unique domain list from FQDNs
$domains = $servers | ForEach-Object {
    if ($_ -match '\.') { ($_ -split '\.', 2)[1].ToLowerInvariant() } else { $null }
} | Where-Object { $_ } | Sort-Object -Unique

if (-not $domains) { throw "No domains detected. Expected FQDNs like server.domain.tld in $ServerListPath" }

# Prompt once per domain
$credsByDomain = @{}
foreach ($d in $domains) {
    $credsByDomain[$d] = Get-Credential -Message "Enter credentials for domain: $d"
}

# Cache unreachable domains so we don't retry
$deadDomains = @{}  # domain -> $true

$results = foreach ($fqdn in $servers) {
    if ($fqdn -notmatch '\.') {
        [pscustomobject]@{
            Server              = $fqdn
            FQDN                = $fqdn
            Domain              = $null
            FoundInDomain        = $null
            objectOwnercodeGSS   = $null
            objectOwnercodeISO   = $null
            objectOwnerDesignees = $null
            objectOwners         = $null
            Status              = "SKIPPED_INVALID_FQDN"
            Error               = "Input is not an FQDN (missing domain): $fqdn"
        }
        continue
    }

    $name   = ($fqdn -split '\.')[0]
    $domain = ($fqdn -split '\.', 2)[1].ToLowerInvariant()

    if ($deadDomains.ContainsKey($domain)) {
        [pscustomobject]@{
            Server              = $name
            FQDN                = $fqdn
            Domain              = $domain
            FoundInDomain        = $null
            objectOwnercodeGSS   = $null
            objectOwnercodeISO   = $null
            objectOwnerDesignees = $null
            objectOwners         = $null
            Status              = "SKIPPED_DOMAIN_UNREACHABLE"
            Error               = "Domain marked unreachable earlier in this run"
        }
        continue
    }

    if (-not $credsByDomain.ContainsKey($domain)) {
        [pscustomobject]@{
            Server              = $name
            FQDN                = $fqdn
            Domain              = $domain
            FoundInDomain        = $null
            objectOwnercodeGSS   = $null
            objectOwnercodeISO   = $null
            objectOwnerDesignees = $null
            objectOwners         = $null
            Status              = "SKIPPED_NO_CREDS"
            Error               = "No credentials stored for domain: $domain"
        }
        continue
    }

    try {
        $adObj = Get-ADComputer -Identity $name -Server $domain -Credential $credsByDomain[$domain] -Properties $attrs -ErrorAction Stop

        $designees = $adObj.objectOwnerDesignees
        if ($designees -is [System.Array]) { $designees = ($designees -join "; ") }

        $owners = $adObj.objectOwners
        if ($owners -is [System.Array]) { $owners = ($owners -join "; ") }

        [pscustomobject]@{
            Server              = $name
            FQDN                = $fqdn
            Domain              = $domain
            FoundInDomain        = $domain
            objectOwnercodeGSS   = $adObj.objectOwnercodeGSS
            objectOwnercodeISO   = $adObj.objectOwnercodeISO
            objectOwnerDesignees = $designees
            objectOwners         = $owners
            Status              = "OK"
            Error               = $null
        }
    }
    catch {
        $msg = $_.Exception.Message

        # If domain/DC connectivity problem, mark domain as dead for the rest of the run
        if ($msg -match '(?i)server is not operational|cannot contact|unavailable|RPC server is unavailable|LDAP server is unavailable|specified domain either does not exist|A referral was returned') {
            $deadDomains[$domain] = $true
            $status = "SKIPPED_DOMAIN_UNREACHABLE"
        }
        elseif ($msg -match '(?i)cannot find an object|does not exist') {
            $status = "NOT_FOUND"
        }
        else {
            $status = "ERROR"
        }

        [pscustomobject]@{
            Server              = $name
            FQDN                = $fqdn
            Domain              = $domain
            FoundInDomain        = $null
            objectOwnercodeGSS   = $null
            objectOwnercodeISO   = $null
            objectOwnerDesignees = $null
            objectOwners         = $null
            Status              = $status
            Error               = $msg
        }
    }
}

$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutputCsv
$results | Format-Table -AutoSize
"Saved: $OutputCsv"
