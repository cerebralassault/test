#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Enable-IISPrereqs {
    param(
        [switch]$AspNet45,
        [switch]$WindowsAuth,
        [switch]$WebSockets,
        [switch]$NetFx3
    )

    $features = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-CommonHttpFeatures",
        "IIS-DefaultDocument",
        "IIS-DirectoryBrowsing",
        "IIS-HttpErrors",
        "IIS-StaticContent",

        "IIS-HttpLogging",
        "IIS-RequestMonitor",

        "IIS-Security",
        "IIS-RequestFiltering",

        "IIS-Performance",
        "IIS-HttpCompressionStatic",
        "IIS-HttpCompressionDynamic",

        "IIS-ApplicationDevelopment",
        "IIS-ISAPIExtensions",
        "IIS-ISAPIFilter",

        "IIS-ManagementConsole",
        "IIS-ManagementService"
    )

    if ($AspNet45) {
        $features += @(
            "IIS-NetFxExtensibility45",
            "IIS-ASPNET45"
        )
    }

    if ($WindowsAuth) {
        $features += "IIS-WindowsAuthentication"
    }

    if ($WebSockets) {
        $features += "IIS-WebSockets"
    }

    if ($NetFx3) {
        $features += "NetFx3"
    }

    $features = $features | Select-Object -Unique

    foreach ($feature in $features) {
        Write-Host "Enabling $feature ..."
        dism /online /enable-feature /featurename:$feature /all /norestart | Out-Null
    }

    Write-Host "IIS prerequisites enabled."
}

# Example usage:
Enable-IISPrereqs -AspNet45 -WindowsAuth
# Enable-IISPrereqs -WebSockets
# Enable-IISPrereqs -NetFx3   # Only if you truly need .NET 3.5
