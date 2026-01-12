function Connect-LDAPSServer {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$PSCR_Path
    )

    if (!(Test-Path $PSCR_Path)) {
        $cred = Get-Credential -Message "Enter ONEID credentials"
        $cred.Password | ConvertFrom-SecureString | Set-Content -Path $PSCR_Path -Force
    }

    $sec = Get-Content $PSCR_Path | ConvertTo-SecureString
    $pwd = (New-Object pscredential($Username,$sec)).GetNetworkCredential().Password

    $id = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Server,$Port,$false,$false)
    $c  = New-Object System.DirectoryServices.Protocols.LdapConnection($id)

    $c.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
    $c.Timeout  = New-TimeSpan -Seconds 30

    $c.SessionOptions.SecureSocketLayer = $true
    $c.SessionOptions.ProtocolVersion   = 3
    $c.SessionOptions.SslProtocol       = [System.Security.Authentication.SslProtocols]::Tls12
    $c.SessionOptions.VerifyServerCertificate = { $true }

    $c.Bind((New-Object System.Net.NetworkCredential($Username,$pwd)))
    return $c
}

function Get-LDAPSQuery {
    param(
        [Parameter(Mandatory=$true)][System.DirectoryServices.Protocols.LdapConnection]$LDAPS_Connection,
        [Parameter(Mandatory=$true)][string]$BaseDN,
        [Parameter(Mandatory=$true)][string]$LDAPS_Filter
    )

    $req = New-Object System.DirectoryServices.Protocols.SearchRequest(
        $BaseDN, $LDAPS_Filter,
        [System.DirectoryServices.Protocols.SearchScope]::Subtree
    )

    for ($i=1; $i -le 3; $i++) {
        try {
            return $LDAPS_Connection.SendRequest($req)
        } catch [System.DirectoryServices.Protocols.DirectoryOperationException] {
            $rc = $_.Exception.Response.ResultCode
            if ($rc -in @(
                [System.DirectoryServices.Protocols.ResultCode]::Busy,
                [System.DirectoryServices.Protocols.ResultCode]::Unavailable,
                [System.DirectoryServices.Protocols.ResultCode]::ServerDown
            ) -and $i -lt 3) {
                Start-Sleep -Seconds (2 * $i)
                continue
            }
            throw "LDAPS query failed (ResultCode=$rc): $($_.Exception.Message)"
        }
    }
}
