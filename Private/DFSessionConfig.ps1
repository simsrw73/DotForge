#Requires -Version 7.0

# The session's configuration: the hashtable passed to Start-DFSession -Config,
# stored here once and read only through Get-DFConfig. Nothing reads a global
# $DFConfig. Before Start-DFSession runs (e.g. a script importing DotForge only
# for its helpers), every read returns its default.
$script:DFSessionConfig = @{}

# Every key DotForge or a companion reads. tests/DFSessionConfig.Tests.ps1 fails
# when code reads a key that is missing here. Value: a one-line description.
$script:DFConfigKeys = [ordered]@{
    Tools              = 'Tools and +groups to configure (Start-DFSession)'
    ExcludeTools       = 'Tools and +groups removed from Tools'
    Defaults           = 'Role -> preferred tool'
    Theme              = 'Shared theme name'
    SkipSetup          = 'Tools whose one-time setup never runs'
    SkipConflictCheck  = 'Skip the coreutils shadowing check'
    IgnoreConflicts    = 'Command names left out of the shadowing check'
    ShimsPath          = 'Folder New-DFShim writes to'
    InstallVia          = 'Tool -> source to install it from (beats everything, including ExcludeSources)'
    InstallOrder        = 'Preferred source order for Install-DFTool (ordering only)'
    ExcludeSources      = 'Sources Install-DFTool never uses (unless InstallVia names one)'
    BatTheme           = 'bat theme'
    DeltaTheme         = 'delta theme'
    FzfTheme           = 'fzf theme'
    GlowTheme          = 'glow theme'
    MdcatTheme         = 'mdcat theme'
    MdvTheme           = 'mdv theme'
    MoorTheme          = 'moor theme'
    VividTheme         = 'vivid (LS_COLORS) theme'
    PSReadLineTheme    = 'PSReadLine theme'
    PSReadLineEditMode = 'PSReadLine edit mode'
    DotenvSafeMode     = 'ps-dotenv safe mode'
    DotenvApprovedDirs = 'Folders ps-dotenv may load .env files from'
}

# Keys that existed before and what replaced them.
$script:DFRemovedConfigKeys = @{
    PackageManagerOrder = 'use InstallOrder (sources, ordering only) and ExcludeSources'
    SkipTools      = 'list the tools you want in Tools, and unwanted members of a +group in ExcludeTools'
    CompletionMode = "set Defaults['tab-completion'] = 'inshellisense' to use inshellisense"
}

function Set-DFSessionConfig {
    <#
    .SYNOPSIS
        Validates a configuration hashtable and stores a copy as the session's configuration.
    .DESCRIPTION
        Called by Start-DFSession. An unknown key warns, suggesting the known
        key it most likely misspells; a key that was removed warns with what
        replaced it. Warnings never stop the session. The stored copy is
        shallow: later changes to the caller's hashtable don't affect it.
    .PARAMETER Config
        The configuration passed to Start-DFSession -Config.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $known = [string[]]$script:DFConfigKeys.Keys
    foreach ($key in $Config.Keys) {
        if ($script:DFConfigKeys.Contains($key)) { continue }
        if ($script:DFRemovedConfigKeys.ContainsKey($key)) {
            Write-Warning "DotForge: config key '$key' was removed — $($script:DFRemovedConfigKeys[$key])."
            continue
        }
        $suggestion = Get-DFFieldSuggestion -Name $key -Known $known
        $hint = if ($suggestion) { " — did you mean '$suggestion'?" } else { ' (ignored)' }
        Write-Warning "DotForge: unknown config key '$key'$hint"
    }
    $script:DFSessionConfig = Copy-DFConfigValue $Config
    $script:DFSessionConfigured = $true
}

function Copy-DFConfigValue {
    <#
    .SYNOPSIS
        Deep-copies a config value: dictionaries and lists are copied recursively, scalars returned as is.
    .DESCRIPTION
        The session snapshot must not share nested objects (the Defaults
        hashtable, list settings) with the caller's hashtable, or changing
        them after Start-DFSession would silently change the session.
    .PARAMETER Value
        The value to copy.
    .OUTPUTS
        System.Object. Dictionaries come back as hashtables, lists as object arrays.
    #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($k in $Value.Keys) { $copy[$k] = Copy-DFConfigValue $Value[$k] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , [object[]]@(foreach ($item in $Value) { Copy-DFConfigValue $item })
    }
    $Value
}

$script:DFSessionConfigured = $false
$script:DFLegacyConfigWarned = $false

function Assert-DFSessionConfigured {
    <#
    .SYNOPSIS
        Warns, once per session, when an old-style global $DFConfig exists but was never passed to Start-DFSession.
    .DESCRIPTION
        DotForge no longer reads a global $DFConfig. A profile that still sets
        one would otherwise lose its settings silently, including protective
        ones (SkipSetup keeps a tool's one-time setup from changing files such
        as your global git config; DotenvSafeMode and DotenvApprovedDirs limit
        which .env files load). Failing open silently is the wrong default, so
        this says so loudly. It only tests that the variable exists; it never
        reads its values.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if ($script:DFSessionConfigured -or $script:DFLegacyConfigWarned) { return }
    if (-not (Test-Path variable:global:DFConfig)) { return }
    $script:DFLegacyConfigWarned = $true
    Write-Warning ("DotForge: a global `$DFConfig was found but is no longer read, so none of its settings apply " +
        "(including SkipSetup, DotenvSafeMode and DotenvApprovedDirs). Pass it explicitly: Start-DFSession -Config `$DFConfig")
}
