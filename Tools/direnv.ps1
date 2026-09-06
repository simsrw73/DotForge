# Companion for direnv — per-directory .envrc loading.
#
# direnv's pwsh hook attaches to
# $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction (fires on
# Set-Location), not function:prompt like zoxide/oh-my-posh — so unlike that
# pair (see CLAUDE.md's prompt-hook-ordering note), registration order
# relative to them doesn't matter here.
#
# The hook requires PowerShell 7.2+ and throws below that (direnv's own
# generated script does `if ($PSVersionTable.PSVersion... -lt 7.2) { throw }`);
# guard here so a PS 7.0/7.1 session degrades to a warning instead of a
# broken one. Not unit tested: $PSVersionTable is AllScope+Constant, so it
# cannot be shadowed or overridden from a test to exercise the else branch
# without an actual sub-7.2 PowerShell install. The generated hook text
# embeds direnv.exe's own resolved path, so it's still a pure function of
# the binary for Get-DFCachedCommandOutput's path+mtime fingerprint (same
# pattern as Tools/zoxide.ps1).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

if ($PSVersionTable.PSVersion -ge [version]'7.2') {
    Invoke-Expression (Get-DFCachedCommandOutput -Name 'direnv-hook' -Executable 'direnv' -Generate {
        direnv hook pwsh | Out-String
    })
} else {
    Write-Warning "DotForge: direnv requires PowerShell 7.2+ (found $($PSVersionTable.PSVersion)) — hook not installed."
}
