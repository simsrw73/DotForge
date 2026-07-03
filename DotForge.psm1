#Requires -Version 7.0

# Load private functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

# Load and export public functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

# Sane 5-column default when DotForge.ToolInfo objects hit Format-Table
# (interactive card/table rendering is handled by Find-DFPackage itself).
Update-TypeData -TypeName 'DotForge.ToolInfo' `
    -DefaultDisplayPropertySet Name, Installed, InstalledVia, Description -Force
