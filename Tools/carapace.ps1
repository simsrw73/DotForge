# Companion for carapace — registers native argument completers for ~519 commands.
# Reads: $DFConfig.CompletionMode (via Get-DFCompletionMode).
# Writes: bundled specs to $XDG_CONFIG_HOME\carapace\specs\*.yaml, and the cached
# init script under $XDG_CACHE_HOME\dotforge\ (Get-DFCachedCommandOutput).
# Sets: CARAPACE_BRIDGES (adds 'inshellisense', see below); carapace's own init
# prepends $XDG_CONFIG_HOME\carapace\bin to PATH.
# Invoke-Expression is required by carapace's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# carapace's init emits Register-ArgumentCompleter calls only — it never binds Tab
# and never overrides TabExpansion. Tab itself is bound once, after every tool has
# registered, by Initialize-DFCompletionStack (PSFzf's fuzzy Tab when PSFzf is
# registered, otherwise PSReadLine's MenuComplete); both route through
# TabExpansion2, which consults these completers. Registration order is
# irrelevant, so no dependsOn on PSFzf is declared. (carapace.json does declare
# "dependsOn": ["fnm"] so fnm puts the Node-hosted `is` on PATH before the bridge
# check below.)
#
# Argument completers are registered session-wide by the engine regardless of the
# scope Invoke-Expression runs in, so dot-sourcing from Register-DFTool is safe.
#
# Known deviation: carapace's generated init prepends $XDG_CONFIG_HOME/carapace/bin
# to PATH itself (the bridge-shim directory) instead of going through Add-DFToPath.
# That line is emitted by carapace, not DotForge, and cannot be rerouted.
#
# Bridges: in Native completion mode, when inshellisense (`is`) is on PATH,
# 'inshellisense' is appended to CARAPACE_BRIDGES so commands carapace has no
# completer for fall back to inshellisense's specs. Bridge entries the user set
# are kept. Other bridges (zsh/fish/bash) are left to the user: each shells out
# once per completion.
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
#
# The init script is a pure function of carapace's own build (verified
# byte-identical across runs) -- cached keyed to the binary's own file
# identity so a carapace upgrade regenerates it. See
# docs/superpowers/specs/2026-09-05-startup-perf-audit.md.
$_carapaceInit = Get-DFCachedCommandOutput -Name 'carapace-init' -Executable 'carapace' -Generate {
    carapace _carapace powershell | Out-String
}
if (((Get-DFCompletionMode) -eq 'Native') -and (Get-Module -ListAvailable -Name PSFzf)) {
    # Trimming could leave an empty CompletionText, which [CompletionResult]::new
    # rejects -- drop whitespace-only items before they reach the constructor.
    $_carapaceInit = $_carapaceInit.Replace(
        'ConvertFrom-Json | ForEach-Object {',
        'ConvertFrom-Json | Where-Object { ([string]$_.CompletionText).Trim() } | ForEach-Object {')
    $_carapaceInit = $_carapaceInit.Replace(
        '[CompletionResult]::new($_.CompletionText,',
        '[CompletionResult]::new(([string]$_.CompletionText).TrimEnd(),')
}

# When carapace has no completions it returns "" to suppress PowerShell's file
# fallback. pwsh 7.6 turns that "" into [CompletionResult]::new(''), which throws;
# PSFzf's Tab handler swallows the exception, so Tab silently does nothing (e.g.
# `ls ..\<Tab>` -- carapace does not understand the backslash prefix). A bare
# return lets PowerShell fall back to filesystem completion instead. No-ops if
# carapace changes that codegen. Catalogued in docs/external-dependencies.md.
$_carapaceInit = $_carapaceInit.Replace('return "" # prevent default file completion', 'return')
Invoke-Expression $_carapaceInit
