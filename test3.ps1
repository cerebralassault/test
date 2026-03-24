# Set to $true to preview, $false to delete
$dryRun = $true

$output_FileName = "c:\temp\RJC0031_deleted.csv"
$user_Name = "BUD\RJC0031"
$search_Path = "\\domain3\wrkgrp\E"
$file_Type = "*.onetoc2"

Remove-Item $output_FileName -Force -ErrorAction SilentlyContinue

$results = New-Object System.Collections.ArrayList

Get-ChildItem -Path $search_Path -Filter $file_Type -Recurse -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
        $owner = (Get-Acl $_.FullName).Owner
        if ($owner -eq $user_Name) {
            if ($dryRun) {
                Write-Output "Would delete: $($_.FullName)"
            }
            else {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                    Write-Output "Deleted: $($_.FullName)"
                }
                catch {
                    Write-Warning "Failed: $($_.FullName) - $($_.Exception.Message)"
                }
            }
            [void]$results.Add([PSCustomObject]@{
                Owner    = $owner
                FullName = $_.FullName
            })
        }
    }

$results | Export-Csv $output_FileName -NoTypeInformation
Write-Output "Total files: $($results.Count)"
Write-Output "Script finished on: $(Get-Date -Format g)"
