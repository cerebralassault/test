# Connect securely to OneID via LDAPS
function Connect-LDAPSServer {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$false)][string]$BaseDN,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$PSCR_Path
    )

    $key = (1..32)

    if (!(Test-Path $PSCR_Path)) {
        $cred = Get-Credential -Message "Enter ONEID credentials"
        $cred.Password | ConvertFrom-SecureString -Key $key | Set-Content -Path $PSCR_Path -Force
    }

    $sec = Get-Content -Path $PSCR_Path | ConvertTo-SecureString -Key $key
    $pwd = (New-Object pscredential($Username, $sec)).GetNetworkCredential().Password

    $id = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Server, $Port, $false, $false)
    $c  = New-Object System.DirectoryServices.Protocols.LdapConnection($id)

    $c.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
    $c.Timeout  = New-TimeSpan -Seconds 30

    $c.SessionOptions.SecureSocketLayer = $true
    $c.SessionOptions.ProtocolVersion  = 3
    $c.SessionOptions.ReferralChasing  = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None

    # Keep if you need it; otherwise remove and validate the cert chain properly
    $c.SessionOptions.VerifyServerCertificate = { $true }

    $c.Bind((New-Object System.Net.NetworkCredential($Username, $pwd)))
    return $c
}
