# Companion for starship — prompt engine init
# Dot-sourced by Register-DFTool when starship is registered. The config path
# comes from STARSHIP_CONFIG (starship.json xdg.vars), applied before this runs.
# Invoke-Expression is required by starship's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
# --print-full-init emits the whole script instead of a stub that re-spawns
# starship to fetch it. The output is a pure function of starship's own build
# (verified byte-identical across runs; the session key is generated at
# runtime inside the script), so it is cached keyed to the binary's identity
# and a starship upgrade regenerates it. starship must init before zoxide,
# which wraps the prompt function — zoxide.json's dependsOn enforces the order.
Invoke-Expression (Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship' -Generate {
    starship init powershell --print-full-init | Out-String
})
# The init script wraps its helpers in a dynamic module ('starship', exporting
# Enable-/Disable-TransientPrompt). New-Module imports into the calling scope,
# which here is DotForge's module scope, so the user could never call them.
# Re-import it globally via the command's own module (a dynamic module that was
# never Import-Module'd is not listed by Get-Module). prompt itself is declared
# global: and is unaffected. Missing command = older/newer starship: skip quietly.
$starshipModule = (Get-Command Enable-TransientPrompt -ErrorAction Ignore)?.Module
if ($starshipModule) { Import-Module -ModuleInfo $starshipModule -Global }
Remove-Variable starshipModule
