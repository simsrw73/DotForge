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

$lines    = @(& choco info $Id 2>$null)
# Format-DFPreviewSummary's -Body crashes on a degenerate single-null/empty-element
# array (e.g. `choco info` returning $null, which `@(...)` wraps as @($null)) — guard
# against that shape before any field extraction.
if (-not ($lines -join '').Trim()) { $lines = @('(choco info produced no output)') }
# Beyond that degenerate case, PowerShell's parameter binder also rejects a
# *non*-degenerate array that merely contains a null/empty-string element anywhere
# in it (Mandatory [string[]] treats any such element as "argument not provided"),
# and real `choco info` output routinely includes blank lines (e.g. the separator
# line before the trailing "N packages found." line). Normalize those to a single
# space so the multi-element array can still bind to -Body below.
$lines = $lines | ForEach-Object { if ([string]::IsNullOrEmpty($_)) { ' ' } else { $_ } }
# Every real field line carries exactly one leading space; strip it so field
# patterns can anchor at column 0. A no-op on lines that have no leading space
# (the banner and header lines).
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
