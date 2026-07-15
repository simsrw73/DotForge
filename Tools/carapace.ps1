# Companion for carapace — registers native argument completers for ~519 commands.
# Invoke-Expression is required by carapace's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# carapace's init emits Register-ArgumentCompleter calls only — it never binds Tab
# and never overrides TabExpansion. That is why it composes with PSFzf rather than
# fighting it: PSFzf owns the Tab key (Tools/PSFzf.ps1) and routes through
# TabExpansion2, which consults these completers. Registration order is irrelevant,
# so no dependsOn is declared.
#
# Argument completers are registered session-wide by the engine regardless of the
# scope Invoke-Expression runs in, so dot-sourcing from Register-DFTool is safe.
#
# Known deviation: carapace's generated init prepends $XDG_CONFIG_HOME/carapace/bin
# to PATH itself (the bridge-shim directory) instead of going through Add-DFToPath.
# That line is emitted by carapace, not DotForge, and cannot be rerouted.
#
# CARAPACE_BRIDGES is deliberately left unset. Bridging (zsh/fish/bash/inshellisense)
# shells out per completion, and of those only bash is present on this machine.
Invoke-Expression (& { (carapace _carapace powershell | Out-String) })
