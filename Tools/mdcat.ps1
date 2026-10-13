# Companion for mdcat — registers mdcat's own PowerShell completions. Its theme is
# declared in Tools/mdcat.json (theme block).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# Native completions. mdcat emits a single Register-ArgumentCompleter -Native
#    call; carapace ships no mdcat spec, so there is no conflict, and it composes
#    with PSFzf's Tab (which routes through TabExpansion2). Invoke-Expression is
#    mdcat's documented init pattern. See docs/external-dependencies.md.
#    The completion script is a pure function of mdcat's own build (verified
#    byte-identical across runs) -- cached keyed to the binary's own file
#    identity so an mdcat upgrade regenerates it. See
#    docs/superpowers/specs/2026-09-05-startup-perf-audit.md.
$_completions = Get-DFCachedCommandOutput -Name 'mdcat-completions' -Executable 'mdcat' -Generate {
    mdcat --completions powershell | Out-String
}
if ($_completions) { Invoke-Expression $_completions }
