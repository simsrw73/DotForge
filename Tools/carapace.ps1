# Companion for carapace — registers native argument completers for ~519 commands.
# Writes: bundled specs to $XDG_CONFIG_HOME\carapace\specs\*.yaml, and the cached
# init script under $XDG_CACHE_HOME\dotforge\ (Get-DFCachedCommandOutput).
# Sets: CARAPACE_BRIDGES (adds 'inshellisense', see below); carapace's own init
# prepends $XDG_CONFIG_HOME\carapace\bin to PATH.
# Invoke-Expression is required by carapace's init pattern — no alternative exists.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

function Enable-DFCarapaceInshellisenseBridge {
    <#
    .SYNOPSIS
        Adds inshellisense to CARAPACE_BRIDGES when it is installed but does not own Tab.
    .DESCRIPTION
        Retains user bridges, removes duplicate entries case-insensitively, and
        leaves the setting alone when inshellisense is the tab-completion winner.
    .OUTPUTS
        System.Boolean. True when the bridge is enabled.
    #>
    [CmdletBinding()]
    param([string]$TabCompletionWinner)
    $executable = Get-Command is -ErrorAction Ignore
    if (-not $executable) { $executable = Get-Command inshellisense -ErrorAction Ignore }
    if (-not $executable -or $TabCompletionWinner -eq 'inshellisense') { return $false }
    $bridges = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($bridge in @($Env:CARAPACE_BRIDGES -split ',')) { $name = $bridge.Trim(); if ($name -and $seen.Add($name)) { $bridges.Add($name) } }
    if ($seen.Add('inshellisense')) { $bridges.Add('inshellisense') }
    $Env:CARAPACE_BRIDGES = $bridges -join ','
    $true
}

# carapace's init emits Register-ArgumentCompleter calls only — it never binds Tab
# and never overrides TabExpansion. Tab itself is bound once, after every tool has
# registered. Tab ownership is selected by the tab-completion role; both route through
# TabExpansion2, which consults these completers. Registration order is
# irrelevant, so no after on PSFzf is declared. (carapace.json does declare
# "after": ["fnm"] so fnm puts the Node-hosted `is` on PATH before the bridge
# check below.)
#
# Argument completers are registered session-wide by the engine regardless of the
# scope Invoke-Expression runs in, so dot-sourcing from Register-DFTool is safe.
#
# Known deviation: carapace's generated init prepends $XDG_CONFIG_HOME/carapace/bin
# to PATH itself (the bridge-shim directory) instead of going through Add-DFToPath.
# That line is emitted by carapace, not DotForge, and cannot be rerouted.
#
# Bridges: when inshellisense (`is`) is on PATH and did not win Tab,
# 'inshellisense' is appended to CARAPACE_BRIDGES so commands carapace has no
# completer for fall back to inshellisense's specs. Bridge entries the user set
# are kept. Other bridges (zsh/fish/bash) are left to the user: each shells out
# once per completion.
$_tabWinner = (Get-DFRole 'tab-completion').Winner
Enable-DFCarapaceInshellisenseBridge -TabCompletionWinner $_tabWinner | Out-Null

# Deploy bundled specs (e.g. scoop, which carapace ships no completer for) into
# carapace's spec directory. carapace auto-loads *.yaml from there — see
# `carapace --help` ("Specs are loaded from ..."). We overwrite DotForge-shipped
# specs (matched by filename) so fixes propagate; users wanting a custom scoop
# spec can place it elsewhere or edit the deployed copy, which is refreshed only
# when the bundled content changes.
$_bundledSpecs = Join-Path $PSScriptRoot 'carapace' 'specs'
if (Test-Path $_bundledSpecs) {
    $_specDir = Join-Path (Get-DFXdgPath Config) 'carapace' 'specs'
    New-DFDirectory $_specDir | Out-Null
    Get-ChildItem $_bundledSpecs -Filter '*.yaml' | ForEach-Object {
        $_dest = Join-Path $_specDir $_.Name
        $_new = Get-Content $_.FullName -Raw
        if (-not (Test-Path $_dest) -or (Get-Content $_dest -Raw) -ne $_new) {
            Set-Content -Path $_dest -Value $_new -Encoding UTF8 -NoNewline   # byte-identical, so the compare above matches next time
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
# carapace registers a completer per command it knows, including commands that
# only have a user spec in the specs folder, so the folder's contents are part of
# the cache key: adding, removing or editing a spec regenerates the init script.
$_specKey = if ($_specDir -and (Test-Path $_specDir)) {
    (Get-ChildItem $_specDir -Filter '*.yaml' -File | Sort-Object Name |
        ForEach-Object { "$($_.Name):$($_.LastWriteTimeUtc.Ticks)" }) -join ','
}
$_carapaceInit = Get-DFCachedCommandOutput -Name 'carapace-init' -Executable 'carapace' -ExtraKey $_specKey -Generate {
    carapace _carapace powershell | Out-String
}
if ($_tabWinner -eq 'PSFzf') {
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

function Initialize-DFRoleTabCompletion {
    param($Tool, $Role)
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}
