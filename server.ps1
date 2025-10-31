# Path to CSV input file with FQDNs (one per line, no header)
$inputFile = "servers.txt"
$servers = Get-Content -Path $inputFile

if (-not $servers) {
    Write-Error "No servers found in $inputFile"
    exit
}

# Extract unique domain parts from FQDNs (everything after first dot)
$domains = $servers | ForEach-Object {
    $parts = $_ -split '\.'
    if ($parts.Count -gt 1) {
        ($parts[1..($parts.Count - 1)] -join '.')
    }
} | Sort-Object -Unique

# Prompt once for credentials per domain
$creds = @{}
foreach ($domain in $domains) {
    Write-Host "Enter credentials for domain $domain"
    $creds[$domain] = Get-Credential -Message "Credentials for $domain"
}

# Prepare output collection
$results = @()

foreach ($server in $servers) {
    # Extract domain from FQDN
    $parts = $server -split '\.'
    if ($parts.Count -gt 1) {
        $domain = ($parts[1..($parts.Count - 1)] -join '.')
    } else {
        $domain = ""
    }

    $credential = $creds[$domain]
    $methodUsed = ""
    $sizeGB = $freeGB = $usedGB = $percentUsed = $errorMsg = $null

    try {
        # Test WinRM (WSMan) connectivity using Test-WSMan
        Test-WSMan -ComputerName $server -Credential $credential -ErrorAction Stop | Out-Null
        # WinRM is available, use CIM over WSMan
        $methodUsed = "WSMan"
        try {
            # Use a CIM session to query Win32_LogicalDisk for drive C:
            $session = New-CimSession -ComputerName $server -Credential $credential -ErrorAction Stop
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -CimSession $session
        } catch {
            # If CIM fails, fall back to WMI (DCOM)
            $methodUsed = "WMI"
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" `
                                  -ComputerName $server -Credential $credential -ErrorAction Stop
        }
    } catch {
        # WinRM not available; fall back to WMI
        $methodUsed = "WMI"
        try {
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" `
                                  -ComputerName $server -Credential $credential -ErrorAction Stop
        } catch {
            # Both methods failed; record error
            $errorMsg = $_.Exception.Message
        }
    }

    if ($disk) {
        $sizeGB     = [math]::Round($disk.Size / 1GB, 2)
        $freeGB     = [math]::Round($disk.FreeSpace / 1GB, 2)
        $usedGB     = [math]::Round($sizeGB - $freeGB, 2)
        $percentUsed= if ($sizeGB -gt 0) { [math]::Round(($usedGB / $sizeGB) * 100, 2) } else { 0 }
    } else {
        # Indicate error if we couldn't retrieve disk info
        $sizeGB = $freeGB = $usedGB = $percentUsed = ""
        $methodUsed = if ($errorMsg) { "Error" } else { $methodUsed }
    }

    # Add the result (or error) to the output array
    $results += [PSCustomObject]@{
        Server      = $server
        Domain      = $domain
        'Size(GB)'  = $sizeGB
        'Free(GB)'  = $freeGB
        'Used(GB)'  = $usedGB
        PercentUsed = $percentUsed
        Method      = $methodUsed
    }
}

# Export results to CSV (no type information)
$outputFile = "CDriveSpaceReport.csv"
$results | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "Output exported to $outputFile"
