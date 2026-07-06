#Requires -Version 7.0

# Lazy-loaded, indexed tool-identity guide: canonical tool -> verified
# per-catalog package ids, consulted by Resolve-DFCatalogQueryMerge as an
# additional (never sole, never authoritative-over-Tools/*.json) identity
# source. Ships as data/tool-identities.json; Update-DFToolIdentityGuide can
# place a newer copy under $XDG_DATA_HOME/dotforge/.

function Get-DFToolIdentityGuide {
    <#
    .SYNOPSIS
        Loads (and indexes) the trifle tool-identity guide. Lazy singleton;
        never throws — an unreadable file degrades to an empty, valid,
        harmless guide object.
    .PARAMETER Path
        Override the shipped-side location (a test seam — lets a fixture
        stand in for the real shipped file). The refreshed-vs-shipped
        precedence check against $Env:XDG_DATA_HOME still runs normally
        against this override. Always forces a fresh, uncached read.
    .PARAMETER Force
        Reload from the resolved location, bypassing the singleton cache.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Path,
        [switch]$Force
    )

    if (-not $Path -and -not $Force -and $script:DFToolIdentityGuide) {
        return $script:DFToolIdentityGuide
    }

    $shippedPath = $Path ? $Path : (Join-Path $PSScriptRoot '../data/tool-identities.json')
    $resolvedPath = $shippedPath

    if ($Env:XDG_DATA_HOME) {
        $refreshedPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-identities.json'
        if (Test-Path $refreshedPath) {
            try {
                $shippedUpdated = (Test-Path $shippedPath) ? (Get-Content $shippedPath -Raw | ConvertFrom-Json).updated : $null
                $refreshedUpdated = (Get-Content $refreshedPath -Raw | ConvertFrom-Json).updated
                if (-not $shippedUpdated -or [datetime]$refreshedUpdated -gt [datetime]$shippedUpdated) {
                    $resolvedPath = $refreshedPath
                }
            } catch {
                Write-Verbose "DotForge: unreadable refreshed tool-identity guide '$refreshedPath', using shipped: $_"
            }
        }
    }

    $tryLoadGuide = {
        param($p)
        if (-not (Test-Path $p)) { return $null }
        try {
            $doc = Get-Content $p -Raw | ConvertFrom-Json
            $errs = $null
            if (Test-DFToolIdentityGuideSchema -Database $doc -Errors ([ref]$errs)) { return $doc }
            Write-Verbose "DotForge: tool-identity guide at '$p' failed schema validation: $($errs -join '; ')"
            return $null
        } catch {
            Write-Verbose "DotForge: unreadable tool-identity guide '$p': $_"
            return $null
        }
    }

    $usedRefreshed = ($resolvedPath -ne $shippedPath)
    $raw = & $tryLoadGuide $resolvedPath
    if (-not $raw -and $usedRefreshed) {
        $raw = & $tryLoadGuide $shippedPath
    }

    if (-not $raw -and -not $script:DFToolIdentityGuideWarned) {
        Write-Warning 'DotForge: tool-identity guide is unavailable — cross-catalog identity resolution falls back to Tools/*.json only.'
        $script:DFToolIdentityGuideWarned = $true
    }

    $idIndex = @{}
    if ($raw) {
        foreach ($prop in $raw.tools.PSObject.Properties) {
            $key = $prop.Name
            $entry = $prop.Value
            if (-not $entry.packages) { continue }
            foreach ($pkgProp in $entry.packages.PSObject.Properties) {
                $idIndex["$($pkgProp.Name):$($pkgProp.Value)".ToLowerInvariant()] = $key
            }
        }
    }

    $guide = [pscustomobject]@{
        Raw     = $raw
        IdIndex = $idIndex
    }

    if (-not $Path) { $script:DFToolIdentityGuide = $guide }
    $guide
}
