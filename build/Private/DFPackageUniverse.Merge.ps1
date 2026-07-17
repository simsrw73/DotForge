#Requires -Version 7.0

# Phase C (tool merge) build helpers. Flattens Phase B clusters + singletons
# into the master tools table, losslessly. See
# docs/superpowers/specs/2026-07-16-package-universe-tool-merge-design.md

function ConvertFrom-DFDbNull {
    <#
    .SYNOPSIS
        Coerces a PSSQLite [DBNull] cell to $null; passes any other value through.
    #>
    [CmdletBinding()]
    param($Value)
    if ($Value -is [DBNull]) { $null } else { $Value }
}

function ConvertTo-DFNormalizedLicense {
    <#
    .SYNOPSIS
        Canonical license identifier for single-answer conflict detection:
        lowercased, the word 'license' removed, non-alphanumeric stripped
        ('MIT' and 'MIT License' -> 'mit'). Returns $null for empties AND for
        URL-shaped values -- choco's license column holds LicenseUrl, not an
        SPDX id, so comparing it to winget's 'MIT' would false-conflict on every
        multi-source choco tool. URLs simply do not participate in the check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)

    if (-not $Value) { return $null }
    if ($Value -match '^\s*https?://') { return $null }
    $t = ($Value.ToLowerInvariant() -replace '\blicense\b', '') -replace '[^a-z0-9]', ''
    if ($t -eq '') { return $null }
    $t
}
