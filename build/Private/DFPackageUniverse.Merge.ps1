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

function Select-DFByPriority {
    <#
    .SYNOPSIS
        First non-empty value of $Field across $Members, scanning source names in
        $Order. Returns { Value; Source } ($null/$null when none supply it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members,
        [Parameter(Mandatory)][string[]]$Order,
        [Parameter(Mandatory)][string]$Field
    )
    foreach ($src in $Order) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $v = ConvertFrom-DFDbNull $m.$Field
                if ($null -ne $v -and "$v".Trim() -ne '') {
                    return [pscustomobject]@{ Value = [string]$v; Source = $src }
                }
            }
        }
    }
    [pscustomobject]@{ Value = $null; Source = $null }
}

function Resolve-DFPackageUniverseToolRecord {
    <#
    .SYNOPSIS
        Reduces one group's member rows to the canonical parent tool record.
        Display scalars are per-field priority picks (winget>choco>scoop) with
        provenance; repo_url uses the Phase B repo authority (choco>scoop>winget);
        a post-normalization license disagreement sets NeedsReview.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members)

    $display = @('winget', 'choco', 'scoop')
    $name = Select-DFByPriority -Members $Members -Order $display -Field 'name'
    $desc = Select-DFByPriority -Members $Members -Order $display -Field 'description'
    # Not named $home -- that's PowerShell's read-only automatic variable and
    # assigning to it throws SessionStateUnauthorizedAccessException.
    $hp = Select-DFByPriority -Members $Members -Order $display -Field 'homepage'
    $lic  = Select-DFByPriority -Members $Members -Order $display -Field 'license'

    # repo: choco ProjectSourceUrl is the strongest signal (Phase B priority),
    # then scoop checkver/autoupdate, then winget (homepage only).
    $repoUrl = $null
    foreach ($src in @('choco', 'scoop', 'winget')) {
        foreach ($m in $Members) {
            if ($m.source -eq $src) {
                $key = Get-DFPackageUniverseRepoKey -Row $m
                if ($key) { $repoUrl = "https://github.com/$key"; break }
            }
        }
        if ($repoUrl) { break }
    }

    # License single-answer conflict: compare only identifier-shaped licenses
    # (ConvertTo-DFNormalizedLicense drops URLs and empties).
    $norm = @($Members | ForEach-Object { ConvertTo-DFNormalizedLicense -Value (ConvertFrom-DFDbNull $_.license) } | Where-Object { $_ } | Select-Object -Unique)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($norm.Count -gt 1) {
        $raw = @($Members | ForEach-Object { ConvertFrom-DFDbNull $_.license } | Where-Object { $_ -and $_ -notmatch '^\s*https?://' } | Select-Object -Unique)
        $reasons.Add("license-conflict: $($raw -join ' | ')")
    }

    $nameVal = if ($name.Value) { $name.Value } else { [string](@($Members)[0].package_id) }

    [pscustomobject]@{
        Name              = $nameVal
        NameSource        = $name.Source
        Description       = $desc.Value
        DescriptionSource = $desc.Source
        Homepage          = $hp.Value
        RepoUrl           = $repoUrl
        License           = $lic.Value
        SourceCount       = @($Members | ForEach-Object { $_.source } | Select-Object -Unique).Count
        NeedsReview       = ($reasons.Count -gt 0)
        ReviewReasons     = $reasons.ToArray()
    }
}
