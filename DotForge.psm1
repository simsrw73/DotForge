#Requires -Version 7.0

# Load private functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

# Load and export public functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }
