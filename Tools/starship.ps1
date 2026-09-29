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
