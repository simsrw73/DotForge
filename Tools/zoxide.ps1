# Companion for zoxide — initialize z/zi with pwd hook (PS7+ only)
# Invoke-Expression is required by zoxide's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
# --hook pwd wraps the prompt function but only calls zoxide add when the directory
# actually changes (vs --hook prompt which calls it every render). oh-my-posh must
# init before this runs so zoxide wraps OMP's prompt correctly.
Invoke-Expression (& { (zoxide init --hook pwd --cmd z powershell | Out-String) })
