# Companion for fnm — Fast Node Manager with --use-on-cd auto-switching.
#
# `fnm env --use-on-cd` defines a global `Set-LocationWithFnm` wrapper and rebinds
# `cd` to it (`Set-Alias -Option AllScope -Scope global cd Set-LocationWithFnm`).
# That wrapper calls plain `Set-Location`, so on its own it REPLACES zoxide's smart
# `cd` (zoxide emits `Set-Alias cd __zoxide_z`) and the directory-jump is lost.
#
# To let both coexist:
#   1. Capture whatever currently owns `cd` (zoxide's __zoxide_z if zoxide ran
#      first, else Set-Location) into $global:cdBeforeFnm.
#   2. Let fnm install its env + Set-LocationWithFnm/cd hook.
#   3. Re-point Set-LocationWithFnm at the captured command so `cd` performs the
#      zoxide jump AND fnm's per-directory Node switch.
#
# Step 1 only recovers zoxide's binding if zoxide registered first, so fnm.json
# declares "dependsOn": ["zoxide"] and Register-DFTool topo-sorts zoxide ahead of
# fnm. With zoxide absent, $global:cdBeforeFnm falls back to Set-Location and fnm
# still works standalone.
#
# Invoke-Expression is required by fnm's init pattern — no alternative exists.
# $global:cdBeforeFnm must be global: fnm's `cd` alias resolves Set-LocationWithFnm
# in the global scope at call time, and that function reads the captured command
# from there — a narrower scope would be invisible to it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()

# 1. Capture the current `cd` target before fnm overwrites it. zoxide binds `cd`
#    as an alias, so .ReferencedCommand yields the callable __zoxide_z function.
$global:cdBeforeFnm = (Get-Alias 'cd' -Scope Global -ErrorAction Ignore).ReferencedCommand
if ($null -eq $global:cdBeforeFnm) { $global:cdBeforeFnm = Get-Command Set-Location }

# 2. Install fnm's environment and its --use-on-cd hook (defines Set-FnmOnLoad,
#    Set-LocationWithFnm, and rebinds the `cd` alias).
fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression

# 3. Chain fnm's wrapper back through the captured `cd`. fnm's `cd` alias resolves
#    Set-LocationWithFnm by name, so redefining the function is enough — no need to
#    touch the alias. Forward @args (not fnm's single $path) so zoxide's multi-
#    keyword queries (`cd foo bar`) and `cd -`/`cd +` survive intact.
function global:Set-LocationWithFnm {
    if ($args.Count -eq 0) { & $global:cdBeforeFnm } else { & $global:cdBeforeFnm @args }
    Set-FnmOnLoad
}
