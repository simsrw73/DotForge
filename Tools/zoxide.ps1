# Companion for zoxide — initialize z/zi with pwd hook (PS7+ only)
# Invoke-Expression is required by zoxide's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
# --hook pwd wraps the prompt function but only calls zoxide add when the directory
# actually changes (vs --hook prompt which calls it every render). A prompt engine
# (oh-my-posh or starship) must init before this runs so zoxide wraps its prompt
# rather than being replaced by it -- zoxide.json's "after" enforces the order.
# --cmd cd replaces the built-in `cd` alias with `cd`/`cdi` -> __zoxide_z/__zoxide_zi.
# zoxide emits `Set-Alias -Name cd -Option AllScope -Force`, so it overrides the
# built-in alias in place (alias-replaces-alias; no function-shadowing issue).
#
# The init script is a pure function of zoxide's own build (verified
# byte-identical across runs) -- cached keyed to the binary's own file
# identity so a zoxide upgrade regenerates it. See
# docs/superpowers/specs/2026-09-05-startup-perf-audit.md.
function Initialize-DFRoleNavigation {
    # Called by DotForge only when zoxide wins the navigation role.
    param([PSCustomObject]$Tool, [string]$Role)
    Invoke-Expression (Get-DFCachedCommandOutput -Name 'zoxide-init' -Executable 'zoxide' -Generate {
        zoxide init --hook pwd --cmd cd powershell | Out-String
    })
}
