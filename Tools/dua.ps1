# Companion for dua: its own PowerShell completer (dua completions powershell),
# cached against its binary (verified byte-identical across runs). Reads nothing
# from $DFConfig; writes no files.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()
$_completions = Get-DFCachedCommandOutput -Name 'dua-completions' -Executable 'dua' -Generate {
    dua completions powershell | Out-String
}
if ($_completions) { Invoke-Expression $_completions }