# Shared helpers for the Pester suite. Dot-source from a test file's BeforeAll:
#     . "$PSScriptRoot/TestSupport.ps1"
# (Not named *.Tests.ps1, so Pester never runs it as a test file.)

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
