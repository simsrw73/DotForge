# Preview formatter for the winget fzf pickers (wins/wrm/wup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `winget show`'s field layout is undocumented CLI text (see
# docs/external-dependencies.md); each field below is pulled independently so one
# field's absence never corrupts another's, and if none match at all this falls
# back to the plain, unmodified `winget show` output.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

$lines = @(& winget show --id $Id 2>$null)
if (-not ($lines -join '').Trim()) { $lines = @('(winget show produced no output)') }

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $lines) {
        if ($line -match $Pattern) { return $Matches[1] }
    }
    return $null
}

$name = $null
if ($lines.Count -gt 0 -and $lines[0] -match '^Found (.+) \[.+\]$') { $name = $Matches[1] }

# Description is a multi-line block: "Description:" (often with no inline value)
# followed by indented continuation lines, up to the next unindented field.
$description = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^Description:\s*(.*)$') {
        if ($Matches[1]) {
            $description = $Matches[1].Trim()
        } else {
            $descLines = [System.Collections.Generic.List[string]]::new()
            for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+\S'; $j++) {
                $descLines.Add($lines[$j].Trim())
            }
            if ($descLines.Count -gt 0) { $description = $descLines -join ' ' }
        }
        break
    }
}

$fields = [ordered]@{
    Name           = $name
    Description    = $description
    Version        = Get-Field '^Version:\s*(.+)$'
    'Last Updated' = Get-Field '^\s+Release Date:\s*(.+)$'
    Publisher      = Get-Field '^Publisher:\s*(.+)$'
    License        = Get-Field '^License:\s*(.+)$'
    Homepage       = Get-Field '^Homepage:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $lines
