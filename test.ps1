#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$features = @(
    # IIS Core
    "IIS-WebServerRole",
    "IIS-WebServer",
    "IIS-CommonHttpFeatures",
    "IIS-DefaultDocument",
    "IIS-DirectoryBrowsing",
    "IIS-HttpErrors",
    "IIS-StaticContent",

    # Health & Diagnostics
    "IIS-HttpLogging",
    "IIS-RequestMonitor",

    # Performance
    "IIS-HttpCompressionStatic",
    "IIS-HttpCompressionDynamic",

    # Security
    "IIS-RequestFiltering",
    "IIS-WindowsAuthentication",

    # Management
    "IIS-ManagementConsole",

    # BITS
    "BITS",
    "BITS-IIS-Ext"
)

foreach ($feature in $features | Select-Object -Unique) {
    Write-Host "Enabling $feature..."
    dism /online /enable-feature /featurename:$feature /all /norestart | Out-Null
}

Write-Host "Distribution Point prerequisites installed."
