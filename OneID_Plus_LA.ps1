# PowerShell Script to Apply GPO Settings Correctly
# Run as Domain Admin on a machine with RSAT/GroupPolicy module

Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

$GpoName = Read-Host "Enter the GPO name to update"
$gpo = Get-GPO -Name $GpoName -ErrorAction Stop

function Set-GpoDword {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [Parameter(Mandatory = $true)][int]$Value
    )
    Set-GPRegistryValue -Name $Name -Key $Key -ValueName $ValueName -Type DWord -Value $Value
}

# Apply registry-based settings (Security Options-style)
Set-GpoDword -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName 'ScForceOption' -Value 0
Set-GpoDword -Name $GpoName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' -ValueName 'LimitBlankPasswordUse' -Value 1
Set-GpoDword -Name $GpoName -Key 'HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters' -ValueName 'EnableForcedLogoff' -Value 1
Set-GpoDword -Name $GpoName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' -ValueName 'ForceLogoffWhenLogonHoursExpire' -Value 1
Set-GpoDword -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName 'InactivityTimeoutSecs' -Value 7200
Set-GpoDword -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters' -ValueName 'SupportedEncryptionTypes' -Value 0x7FFFFFF8
Set-GpoDword -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName 'EnableLUA' -Value 0
Set-GpoDword -Name $GpoName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa\FIPSAlgorithmPolicy' -ValueName 'Enabled' -Value 0

# Ensure GPO has Local Users & Groups CSE registered
$localGroupsCse = '{17D89FEC-5C44-4972-B12D-241CAEF74509}'
$gpoDn = (Get-ADObject -LDAPFilter "(name=$($gpo.Id))" -SearchBase "CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)" -Properties gPCMachineExtensionNames)

if ($gpoDn.gPCMachineExtensionNames -notcontains $localGroupsCse) {
    $updated = $gpoDn.gPCMachineExtensionNames + $localGroupsCse
    Set-ADObject -Identity $gpoDn.DistinguishedName -Replace @{gPCMachineExtensionNames = $updated}
    Write-Host "Registered Local Users & Groups extension in GPO metadata." -ForegroundColor Cyan
} else {
    Write-Host "Local Users & Groups extension already present." -ForegroundColor Gray
}

# Update Local Administrators group via Preferences
$adminSid = 'S-1-5-32-544'
$domain = $gpo.DomainName
$gpoId = $gpo.Id.ToString()
$gpoPath = "\\$domain\SYSVOL\$domain\Policies\{$gpoId}\Machine\Preferences\Groups"
$xmlPath = Join-Path $gpoPath 'Groups.xml'

if (!(Test-Path $gpoPath)) { New-Item -Path $gpoPath -ItemType Directory -Force | Out-Null }

[xml]$xml = if (Test-Path $xmlPath) { Get-Content $xmlPath -Raw } else { $doc = New-Object xml; $doc.AppendChild($doc.CreateElement('Groups')) | Out-Null; $doc }

$groupsNode = $xml.SelectSingleNode('/Groups')

function Add-GroupMember {
    param([string]$AccountName)
    try {
        $sid = ([System.Security.Principal.NTAccount]$AccountName).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        Write-Warning "Could not resolve SID for $AccountName. Skipping."
        return
    }

    $groupNode = $groupsNode.SelectSingleNode("Group[Properties/@sid='$adminSid']")
    if (-not $groupNode) {
        $groupNode = $xml.CreateElement('Group')
        $groupNode.SetAttribute('clsid', '{6C0E44F7-52C4-11D3-8D5A-00105A1F8304}')
        $groupNode.SetAttribute('name', 'Administrators')
        $groupNode.SetAttribute('uid', [guid]::NewGuid().ToString())
        $groupNode.SetAttribute('changed', 'true')

        $props = $xml.CreateElement('Properties')
        $props.SetAttribute('action', 'U')
        $props.SetAttribute('newName', 'Administrators')
        $props.SetAttribute('sid', $adminSid)
        $groupNode.AppendChild($props)

        $groupsNode.AppendChild($groupNode)
    }

    $membersNode = $groupNode.SelectSingleNode('Members')
    if (-not $membersNode) {
        $membersNode = $xml.CreateElement('Members')
        $groupNode.AppendChild($membersNode)
    }

    if ($membersNode.SelectNodes("Member[@sid='$sid']").Count -eq 0) {
        $m = $xml.CreateElement('Member')
        $m.SetAttribute('action', 'ADD')
        $m.SetAttribute('name', $AccountName)
        $m.SetAttribute('sid', $sid)
        $m.SetAttribute('userContext', '0')
        $m.SetAttribute('runAs', '0')
        $m.SetAttribute('delete', '0')
        $membersNode.AppendChild($m) | Out-Null
    }
}

Add-GroupMember "BPAAdmin"
Add-GroupMember "DRE\roleEPUDCOServerOperations"
Add-GroupMember "DRE\vscei-app-00009w-LA"

$xml.Save($xmlPath)

# Force GPO version increment
Set-GPRegistryValue -Name $GpoName -Key 'HKLM\Software\TempGPO' -ValueName 'Trigger' -Type DWord -Value 1
Remove-GPRegistryValue -Name $GpoName -Key 'HKLM\Software\TempGPO' -ValueName 'Trigger'

Write-Host "GPO '$GpoName' updated with registry and local admin settings." -ForegroundColor Green
