#Requires -Version 7.0

# The package catalog and the general helpers are separate modules in Modules/,
# loaded by PowerShell on first use of one of their commands. Putting Modules/ on
# PSModulePath (this process only) is what lets PowerShell find them.
$dfModules = Join-Path $PSScriptRoot 'Modules'
if (($Env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dfModules) {
    $Env:PSModulePath = $dfModules + [IO.Path]::PathSeparator + $Env:PSModulePath
}

# The startup core (Shared/, then Private/, then Public/) loads from one bundled
# file when it is current: ~0.3 s faster than dot-sourcing each file. Any edit not
# yet bundled, or DF_NO_BUNDLE=1, loads the files. See build/Build-DFCoreBundle.ps1.
. (Join-Path $PSScriptRoot 'Bundle' 'CoreSourceHash.ps1')
$dfBundle = Join-Path $PSScriptRoot 'Bundle' 'DotForge.Core.ps1'
$dfUseBundle = $false
if (-not $Env:DF_NO_BUNDLE -and [IO.File]::Exists($dfBundle)) {
    $dfReader = [IO.StreamReader]::new($dfBundle)
    try { $null = $dfReader.ReadLine(); $dfHeader = $dfReader.ReadLine() } finally { $dfReader.Dispose() }
    $dfUseBundle = $dfHeader -eq "# sources-sha256: $(Get-DFCoreSourceHash -Root $PSScriptRoot)"
}
if ($dfUseBundle) {
    . $dfBundle
} else {
    foreach ($dfFile in Get-DFCoreSourceFile -Root $PSScriptRoot) { . $dfFile.FullName }
}
Remove-Variable dfModules, dfBundle, dfUseBundle, dfReader, dfHeader, dfFile -ErrorAction Ignore
