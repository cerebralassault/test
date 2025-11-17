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

# Force GPO version increment
Set-GPRegistryValue -Name $GpoName -Key 'HKLM\Software\TempGPO' -ValueName 'Trigger' -Type DWord -Value 1
Remove-GPRegistryValue -Name $GpoName -Key 'HKLM\Software\TempGPO' -ValueName 'Trigger'

Write-Host "GPO '$GpoName' updated with registry settings and extension metadata." -ForegroundColor Green
