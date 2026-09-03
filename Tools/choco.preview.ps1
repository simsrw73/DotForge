# Preview formatter for the choco fzf pickers (cins/crm/cup). Standalone script —
# invoked by fzf's --preview in a fresh `pwsh -NoProfile` process (no DotForge module
# loaded), so it dot-sources Format-DFPreviewSummary directly by path.
#
# `choco info`'s field layout (see docs/external-dependencies.md) is the most
# irregular of the three: every line carries a uniform one-space indent (no
# top-level-vs-continuation signal), Name/Version are fused into the header line
# (which is preceded by a "Chocolatey vX.Y.Z" banner line, so the header is found
# by scanning, not assumed to be first), the "last updated" date is embedded
# inside the Title line's value rather than its own field, and choco has no
# Publisher-equivalent field. Only the first line of Description is used — choco
# often continues it below with unindented markdown sections (## Features, ##
# Notes, ...) that would swamp a short summary block; that content stays
# visible, unstyled, in the full output below the separator. If no field
# matches at all, this falls back to the plain, unmodified `choco info` output.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private/Format-DFPreviewSummary.ps1')

# Wrapped in a function (rather than calling `& choco info $Id` inline) so tests
# can mock it without requiring choco to actually be installed. Pester's Mock
# needs the target command to already exist, so `Mock -CommandName choco` fails
# with a CommandNotFoundException on a machine/CI runner without choco on PATH —
# even though choco is a real .exe (CommandType Application) that Pester _can_
# mock directly where it is installed. Mocking this wrapper instead works
# everywhere, matching Tools/winget.preview.ps1's Invoke-DFWingetShow and
# Tools/scoop.preview.ps1's Invoke-DFScoopInfo.
function Invoke-DFChocoInfo {
    param([string]$Id)
    & choco info $Id 2>$null
}

$lines = @(Invoke-DFChocoInfo -Id $Id)
# Guard against choco info returning nothing recognizable (e.g. $null, which
# `@(...)` wraps as a single-element array) before any field extraction.
if (-not ($lines -join '').Trim()) { $lines = @('(choco info produced no output)') }
# Every real field line carries exactly one leading space; strip it so field
# patterns can anchor at column 0. A no-op on lines that have no leading space
# (the banner and header lines). Format-DFPreviewSummary normalizes any null/
# empty-string element in $lines itself, so no local guard is needed here for
# that shape (real `choco info` output routinely includes blank lines, e.g. the
# separator before the trailing "N packages found." line).
$stripped = $lines | ForEach-Object { $_ -replace '^ ', '' }

function Get-Field {
    param([string]$Pattern)
    foreach ($line in $stripped) {
        if ($line -match $Pattern) { return $Matches[1].Trim() }
    }
    return $null
}

$name    = $null
$version = $null
foreach ($line in $lines) {
    if ($line -match '^(\S+)\s+(\S+)\s*\[.*\]$') {
        $name    = $Matches[1]
        $version = $Matches[2]
        break
    }
}

$fields = [ordered]@{
    Name           = $name
    Description    = Get-Field '^Description:\s*(.+)$'
    Version        = $version
    'Last Updated' = Get-Field 'Published:\s*(\S+)'
    License        = Get-Field '^Software License:\s*(.+)$'
    Homepage       = Get-Field '^Software Site:\s*(.+)$'
}

Format-DFPreviewSummary -Fields $fields -Body $lines
