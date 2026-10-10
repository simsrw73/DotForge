# Shared helpers for the Pester suite. Dot-source from a test file's BeforeAll:
#     . "$PSScriptRoot/TestSupport.ps1"
# (Not named *.Tests.ps1, so Pester never runs it as a test file.)

# Set-DFTestXdg's save stack. Initialized here (in the test file's script scope,
# where this file is dot-sourced) so the helpers stay StrictMode-safe.
$script:DFTestSavedXdg = [System.Collections.Generic.Stack[hashtable]]::new()

function Set-DFTestConfig {
    <#
    .SYNOPSIS
        Sets the session config the module files read through Get-DFConfig, without validation.
    .DESCRIPTION
        Tests dot-source the module files, so Get-DFConfig reads the test file's
        $script:DFSessionConfig. $null clears it (every Get-DFConfig returns its
        default). Use Set-DFSessionConfig instead to test validation warnings.
            BeforeEach { Set-DFTestConfig @{ Tools = @('bat') } }
            AfterEach  { Set-DFTestConfig $null }
    .PARAMETER Config
        The config hashtable, or $null.
    .OUTPUTS
        None.
    #>
    param([System.Collections.IDictionary]$Config)
    $copy = @{}
    if ($Config) { foreach ($k in $Config.Keys) { $copy[$k] = $Config[$k] } }
    $script:DFSessionConfig = $copy
}

function Reset-DFTestSession {
    <#
    .SYNOPSIS
        Clears the session state Start-DFSession and Register-DFTool keep, so tests don't see each other's tools.
    .DESCRIPTION
        Register-DFTool folds the session's requested tools into each call (so
        role winners are computed over everything requested). Within one test
        file that state persists, so every Describe that registers tools calls
        this from its BeforeEach. Also clears the per-name record cache and
        the full tool DB cache.
    .OUTPUTS
        None.
    #>
    $script:DFSessionStatus = $null
    $script:DFSessionToolDb = @{}
    $script:DFSessionRoleWinners = $null
    $script:DFToolRecordCache = @{}
    $script:DFToolDb = $null
}

function Get-DFTestModuleFile {
    <#
    .SYNOPSIS
        Returns every module source file, in the order DotForge.psm1 loads them.
    .DESCRIPTION
        Tests dot-source the module's own files (rather than Import-Module) so
        Mock works on private functions without -ModuleName. Loading all of them,
        in the psm1's order, replaces hand-maintained per-test load lists: a new
        private dependency can no longer break unrelated test files.

        Dot-sourcing must happen in the test's scope, so this returns paths:
            BeforeAll {
                . "$PSScriptRoot/TestSupport.ps1"
                foreach ($f in Get-DFTestModuleFile) { . $f }
            }
        Tools/*.ps1 companions are not included; a test loads its sidecar itself.
        The on-demand modules (Modules/DotForge.Catalog, Modules/DotForge.Helpers)
        are loaded into the same scope, so a test can reach any function.
    .OUTPUTS
        System.String[]. Absolute paths: Shared/, Private/, Public/, then each
        on-demand module's Private/ and Public/.
    #>
    $root = Split-Path $PSScriptRoot -Parent
    # Same enumeration as DotForge.psm1 (and the on-demand modules' loaders), so
    # load order -- and therefore which $script: initializer runs first -- matches.
    foreach ($dir in Get-DFTestSourceDir) {
        (Get-ChildItem -Path $dir -Filter '*.ps1').FullName
    }
}

function Set-DFTestXdg {
    <#
    .SYNOPSIS
        Points all four XDG_*_HOME variables at folders under $TestDrive, saving the originals.
    .DESCRIPTION
        An unset XDG variable means the real default folder under $HOME
        (Get-DFXdgPath), so a test that can reach any cache/state/config/data
        writer must redirect all four. Pair with Restore-DFTestXdg:
            BeforeEach { Set-DFTestXdg }
            AfterEach  { Restore-DFTestXdg }
        Folders are not created; DotForge creates what it writes.
    .PARAMETER Root
        Parent folder for the four homes. Default: $TestDrive\xdg.
    .OUTPUTS
        None.
    #>
    param([string]$Root = (Join-Path $TestDrive 'xdg'))
    # A stack, so nested use (BeforeAll in a Describe, BeforeEach in a Context
    # inside it) restores each level in turn instead of losing the outer save.
    $saved = @{}
    foreach ($kind in 'CONFIG', 'CACHE', 'DATA', 'STATE') {
        $name = "XDG_${kind}_HOME"
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, (Join-Path $Root $kind.ToLowerInvariant()), 'Process')
    }
    # git's global config too: activating delta runs `git config --global`, and no
    # test may ever change the developer's real one. (Restored with the XDG folders.)
    $saved['GIT_CONFIG_GLOBAL'] = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'Process')
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', (Join-Path $Root 'gitconfig'), 'Process')
    $script:DFTestSavedXdg.Push($saved)
}

function Restore-DFTestXdg {
    <#
    .SYNOPSIS
        Restores the XDG_*_HOME values Set-DFTestXdg saved (unset ones become unset again).
    .OUTPUTS
        None.
    #>
    if ($script:DFTestSavedXdg.Count -eq 0) {
        throw 'Restore-DFTestXdg called without a matching Set-DFTestXdg.'
    }
    foreach ($entry in $script:DFTestSavedXdg.Pop().GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}

function Remove-DFTestGlobal {
    <#
    .SYNOPSIS
        Removes global functions and aliases a test defined, and nothing else.
    .DESCRIPTION
        Remove-Item ignores a scope qualifier on the Function: and Alias:
        drives: `Remove-Item function:global:git` silently does nothing, so a
        stub defined with `function global:git {}` outlived its test and every
        later test file in the run called the stub instead of git.exe.
        An unqualified `Remove-Item function:git` is no better: it removes the
        nearest definition, which may be a copy the test file dot-sourced.

        This runs the removal inside a throwaway module. A module's scope chain
        is module, then global, skipping the caller's scopes, so the name
        resolves to the global definition only.
    .PARAMETER Function
        Global function names to remove. Missing names are ignored.
    .PARAMETER Alias
        Global alias names to remove. Missing names are ignored.
    .EXAMPLE
        AfterEach { Remove-DFTestGlobal -Function git, scoop -Alias sins }
    .OUTPUTS
        None.
    #>
    param([string[]]$Function = @(), [string[]]$Alias = @())
    $scope = New-Module -ScriptBlock { }
    & $scope {
        param($Function, $Alias)
        foreach ($n in $Function) {
            if (Test-Path "function:global:$n") { Remove-Item -LiteralPath "function:$n" -Force }
        }
        foreach ($n in $Alias) {
            # Test-Path alias:global:<n> is always false, even for an existing global
            # alias, so ask Get-Alias for the global scope directly.
            if (Get-Alias -Name $n -Scope Global -ErrorAction Ignore) { Remove-Alias -Name $n -Scope Global -Force }
        }
    } $Function $Alias
}

function Get-DFTestSourceDir {
    <#
    .SYNOPSIS
        Every folder of module source files, in load order: Shared, the core's Private and Public, then each on-demand module's.
    .OUTPUTS
        System.String[]. Absolute folder paths.
    #>
    $root = Split-Path $PSScriptRoot -Parent
    foreach ($d in 'Shared', 'Private', 'Public') { Join-Path $root $d }
    foreach ($m in 'DotForge.Catalog', 'DotForge.Helpers') {
        foreach ($d in 'Private', 'Public') { Join-Path $root 'Modules' $m $d }
    }
}
