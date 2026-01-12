# Perform LDAPS query
function Get-LDAPSQuery {
    param(
        [Parameter(Mandatory=$true)]
        [System.DirectoryServices.Protocols.LdapConnection]$LDAPS_Connection,

        [Parameter(Mandatory=$true)]
        [string]$BaseDN,

        [Parameter(Mandatory=$true)]
        [string]$LDAPS_Filter
    )

    $req = New-Object System.DirectoryServices.Protocols.SearchRequest(
        $BaseDN,
        $LDAPS_Filter,
        [System.DirectoryServices.Protocols.SearchScope]::Subtree
    )

    for ($i = 1; $i -le 3; $i++) {
        try {
            return $LDAPS_Connection.SendRequest($req)
        }
        catch [System.DirectoryServices.Protocols.DirectoryOperationException] {
            $rc  = $_.Exception.Response.ResultCode
            $msg = $_.Exception.Message

            # Specific failure you're seeing: reconnect + retry
            if ($msg -match 'cannot handle directory requests' -and $i -lt 3) {
                try { $LDAPS_Connection.Dispose() } catch {}

                # Uses your existing script-level vars; adjust names if yours differ
                $LDAPS_Connection = Connect-LDAPSServer -Server $ServerName -Port $Port -BaseDN $BaseDN -Username $ONEID_CREDS_DN -PSCR_Path $ONEID_Creds_Path

                Start-Sleep -Seconds (2 * $i)
                continue
            }

            # Transient server conditions: backoff + retry
            if ($rc -in @(
                [System.DirectoryServices.Protocols.ResultCode]::Busy,
                [System.DirectoryServices.Protocols.ResultCode]::Unavailable,
                [System.DirectoryServices.Protocols.ResultCode]::ServerDown
            ) -and $i -lt 3) {
                Start-Sleep -Seconds (2 * $i)
                continue
            }

            throw "LDAPS query failed (ResultCode=$rc): $msg"
        }
        catch {
            if ($i -lt 3) {
                Start-Sleep -Seconds (2 * $i)
                continue
            }
            throw
        }
    }
}
