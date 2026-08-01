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
Enable-DFCarapaceInshellisenseBridge | Out-Null

# Deploy bundled specs (e.g. scoop, which carapace ships no completer for) into
# carapace's spec directory. carapace auto-loads *.yaml from there — see
# `carapace --help` ("Specs are loaded from ..."). We overwrite DotForge-shipped
# specs (matched by filename) so fixes propagate; users wanting a custom scoop
# spec can place it elsewhere or edit the deployed copy, which is refreshed only
# when the bundled content changes.
$_bundledSpecs = Join-Path $PSScriptRoot 'carapace' 'specs'
if (Test-Path $_bundledSpecs) {
    $_specDir = Join-Path ($Env:XDG_CONFIG_HOME ?? (Join-Path $HOME '.config')) 'carapace' 'specs'
    New-DFDirectory $_specDir | Out-Null
    Get-ChildItem $_bundledSpecs -Filter '*.yaml' | ForEach-Object {
        $_dest = Join-Path $_specDir $_.Name
        $_new = Get-Content $_.FullName -Raw
        if (-not (Test-Path $_dest) -or (Get-Content $_dest -Raw) -ne $_new) {
            Set-Content -Path $_dest -Value $_new -Encoding UTF8
        }
    }
}

# carapace appends a trailing space to each CompletionText (its "token complete"
# convention). PSFzf's FixCompletionResult quotes any completion containing a
# space, so a fuzzy-picked `docker build` would land as `docker "build "`. When
# PSFzf will own Tab (Native mode + PSFzf available), trim the trailing space so
# the picker inserts a clean, unquoted value — PSFzf re-adds a single trailing
# space itself. The replacement targets carapace's generated constructor call
# and no-ops (leaving the space intact, which MenuComplete needs for subcommand
# chaining) if carapace ever changes that codegen. Catalogued in
# docs/external-dependencies.md.
$_carapaceInit = carapace _carapace powershell | Out-String
if (((Get-DFCompletionMode) -eq 'Native') -and (Get-Module -ListAvailable -Name PSFzf)) {
    $_carapaceInit = $_carapaceInit.Replace(
        '[CompletionResult]::new($_.CompletionText,',
        '[CompletionResult]::new(([string]$_.CompletionText).TrimEnd(),')
}
Invoke-Expression $_carapaceInit
