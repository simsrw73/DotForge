# Preview formatter for the scoop fzf pickers (sins/srm/sup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `scoop info`'s field layout is undocumented, ANSI-colored CLI text (see
# docs/external-dependencies.md); each field below is pulled independently, after
# stripping the color codes, so one field's absence never corrupts another's. scoop
# has no Publisher-equivalent field, so it is not part of the summary block. If no
# field matches at all, this falls back to the plain, unmodified `scoop info` output.
# In real use that output already comes back ANSI-free (see Invoke-DFScoopInfo
# below) — color codes only appear in this script's own hand-built test fixtures,
# which simulate scoop info's raw, un-piped text.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Name
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

# Exists as a separate function so tests can mock it without spawning a real
# scoop process (same rationale as Private/Invoke-DFFzf.ps1). Also sidesteps a
# Pester 6.1.0 limitation: Mock cannot shadow a bare command name that resolves
# to CommandType ExternalScript, which `scoop` does on any machine with Scoop
# actually installed (its shim is scoop.ps1, not an .exe).
#
# `scoop` resolving to a .ps1 shim also means `&`-invoking it can hand back real
# PowerShell/.NET objects rather than plain text lines: confirmed that
# `scoop info <name>` returns a single [pscustomobject], which stringifies to
# '' when later joined — silently defeating every field-extraction regex below
# and making the empty-output guard fire on every real package. `Out-String
# -Stream` forces whatever scoop info emits (object or text) into a genuine
# string[] of lines. As a side effect it also strips ANSI escape codes, which is
# why the ANSI-stripping regex further below is now a second layer — real
# output no longer needs it, but this script's own hand-built test fixtures
# (which simulate raw, un-piped scoop info text WITH embedded ANSI codes) still
# exercise it, and it stays as cheap insurance if Out-String -Stream's behavior
# or scoop's own output format ever changes.
function Invoke-DFScoopInfo {
    param([string]$Name)
    & scoop info $Name 2>$null | Out-String -Stream
}

$rawLines = @(Invoke-DFScoopInfo -Name $Name)
if (-not ($rawLines -join '').Trim()) { $rawLines = @('(scoop info produced no output)') }
# Second layer of ANSI stripping — see the Invoke-DFScoopInfo comment above.
$lines    = $rawLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' }

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $lines) {
        if ($line -match $Pattern) { return $Matches[1].Trim() }
    }
    return $null
}

$fields = [ordered]@{
    Name           = Get-Field '^Name\s*:\s*(.+)$'
    Description    = Get-Field '^Description\s*:\s*(.+)$'
    Version        = Get-Field '^Version\s*:\s*(.+)$'
    'Last Updated' = Get-Field '^Updated at\s*:\s*(.+)$'
    License        = Get-Field '^License\s*:\s*(.+)$'
    Homepage       = Get-Field '^Website\s*:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $rawLines
