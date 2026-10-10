#Requires -Version 7.2
# DotForge.Helpers: loaded by PowerShell on first use of one of its commands (DotForge adds
# Modules/ to PSModulePath). Stateless helpers come from DotForge's Shared/ (this
# module's own copy); session settings come from DotForge's public Get-DFConfig.

foreach ($dir in (Join-Path $PSScriptRoot '..' '..' 'Shared'), (Join-Path $PSScriptRoot 'Private'), (Join-Path $PSScriptRoot 'Public')) {
    Get-ChildItem -Path $dir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}
