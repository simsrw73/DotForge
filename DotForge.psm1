#Requires -Version 7.0

# The package catalog and the general helpers are separate modules in Modules/,
# loaded by PowerShell on first use of one of their commands. Putting Modules/ on
# PSModulePath (this process only) is what lets PowerShell find them.
$dfModules = Join-Path $PSScriptRoot 'Modules'
if (($Env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dfModules) {
    $Env:PSModulePath = $dfModules + [IO.Path]::PathSeparator + $Env:PSModulePath
}
Remove-Variable dfModules

# Stateless helpers shared with the on-demand modules, then the core.
foreach ($dir in 'Shared', 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}
