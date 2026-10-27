#Requires -Version 7.2

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
    InstallVia          = 'Tool -> source to install it from (beats everything, including IncludeSources and ExcludeSources)'
    InstallOrder        = 'Preferred source order for Install-DFTool (ordering only)'
    IncludeSources      = 'The only sources Install-DFTool uses, registries included (unless InstallVia names another)'
    ExcludeSources      = 'Sources Install-DFTool never uses (unless InstallVia names one)'
    NerdFont           = 'Icons: $true on, $false off; unset detects an installed Nerd Font (Windows)'
    ShowBanner         = 'Show the startup banner (fastfetch, drive health, public IP)'
    BannerLineDelay    = 'Milliseconds between banner lines; 0 prints at once'
    BannerWait         = 'Longest wait, in ms, for an unfinished banner part'
    BannerClear        = 'Clear the screen before the banner; $false keeps scrollback'
    BatTheme           = 'bat theme'
    DeltaTheme         = 'delta theme'
    EzaTheme           = 'eza theme (dates, sizes, permissions)'
    FzfTheme           = 'fzf theme'
    GlowTheme          = 'glow theme'
    LsdTheme           = 'lsd theme (dates, sizes, permissions)'
    GumTheme           = 'gum theme (GUM_* colors)'
    MdcatTheme         = 'mdcat theme'
    MdvTheme           = 'mdv theme'
    MoorTheme          = 'moor theme'
    OvTheme            = 'ov theme (passed with --config unless you have your own ov config)'
    SkimTheme          = 'skim theme'
    DirectoryJumpMinScore = 'lowest zoxide score Alt+C lists (default 3)'
    DirectoryJumpRanked = 'most ranked (zoxide) folders Alt+C lists (default 10)'
    DirectoryJumpDepth = 'how deep Alt+C scans below the current folder (default 6)'
    BrootTheme         = 'broot skin (a catppuccin flavor, or a skin file of your own)'
    StarshipTheme      = 'starship palette (a catppuccin flavor; applied to a copy of your starship.toml)'
    ClaudeTheme        = 'Claude Code theme (a catppuccin flavor through the claude-themes plugin, custom:<plugin>:<theme>, or one of Claude''s own)'
    OhMyPoshTheme      = 'oh-my-posh theme (a catppuccin flavor; used when you have no config of your own)'
    ProcsTheme         = 'procs color theme (dark or light, from Theme)'
    BtopTheme          = 'btop catppuccin flavor named in the setup note (btop.conf is yours)'
    DufTheme           = 'duf theme (dark or light, from Theme)'
    BottomTheme        = 'bottom built-in theme (default, default-light, gruvbox, nord, ...; from Theme)'
    PecoTheme          = 'peco theme (seeded into its config.json once)'
    TelevisionTheme    = 'television theme (seeded into its config.toml once; edit ui.theme there to change it)'
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

function Get-DFConfigFilePath {
    <#
    .SYNOPSIS
        Returns the path of the config file Start-DFSession reads without -Config.
    .DESCRIPTION
        $XDG_CONFIG_HOME/dotforge/config.psd1 (~/.config/dotforge/config.psd1
        when XDG_CONFIG_HOME is unset). The file needn't exist.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    param()
    ConvertTo-DFPath (Join-Path (Get-DFXdgPath Config) 'dotforge' 'config.psd1')
}

function Read-DFConfigFile {
    <#
    .SYNOPSIS
        Reads the config file, or returns an empty configuration with a warning when it is missing or unreadable.
    .DESCRIPTION
        The file is a PowerShell data file (Import-PowerShellDataFile): the same
        keys as Start-DFSession -Config, comments allowed, no code. A file that
        is missing, malformed or holds code warns, naming the file, and yields
        an empty configuration, so a typo never stops a shell from starting.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFConfigFilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Warning "DotForge: no config file at $path, so no tools are configured. Put your settings there (see Get-Help Start-DFSession)."
        return @{}
    }
    try {
        Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
    } catch {
        Write-Warning "DotForge: can't read $path, so no tools are configured: $($_.Exception.Message)"
        @{}
    }
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
