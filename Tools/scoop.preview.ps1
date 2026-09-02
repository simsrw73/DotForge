# Preview formatter for the scoop fzf pickers (sins/srm/sup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `scoop info`'s field layout is undocumented, ANSI-colored CLI text (see
# docs/external-dependencies.md); each field below is pulled independently, after
# stripping the color codes, so one field's absence never corrupts another's. scoop
# has no Publisher-equivalent field, so it is not part of the summary block. If no
# field matches at all, this falls back to the plain, unmodified `scoop info` output
# (color codes intact, exactly as it renders today).
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
function Invoke-DFScoopInfo {
    param([string]$Name)
    & scoop info $Name 2>$null
}

$rawLines = @(Invoke-DFScoopInfo -Name $Name)
if (-not ($rawLines -join '').Trim()) { $rawLines = @('(scoop info produced no output)') }
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
