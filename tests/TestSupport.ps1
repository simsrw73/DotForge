# Shared helpers for the Pester suite. Dot-source from a test file's BeforeAll:
#     . "$PSScriptRoot/TestSupport.ps1"
# (Not named *.Tests.ps1, so Pester never runs it as a test file.)

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
    .OUTPUTS
        System.String[]. Absolute paths: Private/*.ps1, then Public/*.ps1.
    #>
    $root = Split-Path $PSScriptRoot -Parent
    # Same enumeration as DotForge.psm1, so load order (and therefore which
    # $script: initializer runs first) matches the real module.
    foreach ($dir in 'Private', 'Public') {
        (Get-ChildItem -Path (Join-Path $root $dir) -Filter '*.ps1').FullName
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
    $script:DFTestSavedXdg = @{}
    foreach ($kind in 'CONFIG', 'CACHE', 'DATA', 'STATE') {
        $name = "XDG_${kind}_HOME"
        $script:DFTestSavedXdg[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, (Join-Path $Root $kind.ToLowerInvariant()), 'Process')
    }
}

function Restore-DFTestXdg {
    <#
    .SYNOPSIS
        Restores the XDG_*_HOME values Set-DFTestXdg saved (unset ones become unset again).
    .OUTPUTS
        None.
    #>
    if (-not $script:DFTestSavedXdg) { return }
    foreach ($entry in $script:DFTestSavedXdg.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    $script:DFTestSavedXdg = $null
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
