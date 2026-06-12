# Companion for zoxide — initialize z/zi with pwd hook (PS7+ only)
# Invoke-Expression is required by zoxide's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
# --hook pwd wraps the prompt function but only calls zoxide add when the directory
# actually changes (vs --hook prompt which calls it every render). oh-my-posh must
# init before this runs so zoxide wraps OMP's prompt correctly.
# --cmd cd replaces the built-in `cd` alias with `cd`/`cdi` -> __zoxide_z/__zoxide_zi.
# zoxide emits `Set-Alias -Name cd -Option AllScope -Force`, so it overrides the
# built-in alias in place (alias-replaces-alias; no function-shadowing issue).
Invoke-Expression (& { (zoxide init --hook pwd --cmd cd powershell | Out-String) })
