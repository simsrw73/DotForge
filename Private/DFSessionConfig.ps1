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
    PackageManagerOrder = 'Install-DFTool package-manager order'
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
    SkipTools      = 'list the tools you want in Tools, and unwanted members of a +group in ExcludeTools'
    CompletionMode = "set Defaults['tab-completion'] = 'inshellisense' to use inshellisense"
}

function Get-DFConfig {
    <#
    .SYNOPSIS
        Reads one session setting, or returns -Default when it isn't set.
    .DESCRIPTION
        Reads the configuration Start-DFSession stored. A missing key or a
        $null value returns -Default; a configured $false is returned as is.
        Like any PowerShell command, an array value is written to the pipeline
        element by element, so read list settings with @(Get-DFConfig Tools).
    .PARAMETER Key
        The setting name, e.g. 'Tools'. It must be listed in $script:DFConfigKeys.
    .PARAMETER Default
        Returned when the setting isn't configured. Default: $null.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)]$Default = $null
    )
    if ($script:DFSessionConfig.Contains($Key) -and $null -ne $script:DFSessionConfig[$Key]) {
        return $script:DFSessionConfig[$Key]
    }
    $Default
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
    $copy = @{}
    foreach ($key in $Config.Keys) { $copy[$key] = $Config[$key] }
    $script:DFSessionConfig = $copy
}
