#Requires -Version 7.0

# Phase D (categorization) engine helpers. Classifies merged tools into a
# closed taxonomy by reading their docs via an LLM, caching durably. See
# docs/superpowers/specs/2026-07-17-package-universe-categorization-design.md

function Resolve-DFPackageUniverseRepo {
    <#
    .SYNOPSIS
        Resolves a tool's source repository on ANY known forge (github, gitlab,
        bitbucket, codeberg, sr.ht), from source-repo fields in the extra JSON
        (choco ProjectSourceUrl/ProjectUrl, scoop checkver/autoupdate github ref)
        first, then the homepage. Returns { Host; Owner; Repo; Url } or $null.
        Url is canonical: https://<lower-host>/<owner>/<repo>, .git stripped.
    .DESCRIPTION
        Mines candidate URLs in priority order -- choco ProjectSourceUrl,
        ProjectUrl, scoop checkver (string or .github), scoop autoupdate --
        before falling back to Homepage, and returns the first candidate that
        matches a known git-forge URL shape. Strict-mode safe on $null inputs.
    .PARAMETER Homepage
        The tool's homepage URL, used as the fallback candidate.
    .PARAMETER Extra
        Raw JSON string holding source-specific extra fields (choco/scoop).
    .EXAMPLE
        Resolve-DFPackageUniverseRepo -Homepage 'https://github.com/sharkdp/bat'
        Returns @{ Host = 'github.com'; Owner = 'sharkdp'; Repo = 'bat'; Url = 'https://github.com/sharkdp/bat' }
    .OUTPUTS
        [pscustomobject] with Host, Owner, Repo, Url properties, or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Homepage, [AllowNull()][string]$Extra)

    $hosts = 'github\.com', 'gitlab\.com', 'bitbucket\.org', 'codeberg\.org', 'git\.sr\.ht'
    $pattern = "(?:$($hosts -join '|'))[/:]([^/#?\s]+)/([^/#?\s]+)"

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Extra) {
        $doc = $null
        try { $doc = $Extra | ConvertFrom-Json } catch { $doc = $null }
        if ($doc) {
            foreach ($k in 'ProjectSourceUrl', 'ProjectUrl') {
                $p = $doc.PSObject.Properties[$k]; if ($p -and $p.Value) { $candidates.Add([string]$p.Value) }
            }
            $cv = $doc.PSObject.Properties['checkver']
            if ($cv -and $cv.Value) {
                if ($cv.Value -is [string]) { $candidates.Add($cv.Value) }
                else { $gh = $cv.Value.PSObject.Properties['github']; if ($gh -and $gh.Value) { $candidates.Add([string]$gh.Value) } }
            }
            $au = $doc.PSObject.Properties['autoupdate']
            if ($au -and $au.Value) { $candidates.Add((ConvertTo-Json -Compress -Depth 8 -InputObject $au.Value)) }
        }
    }
    if ($Homepage) { $candidates.Add([string]$Homepage) }

    foreach ($c in $candidates) {
        $m = [regex]::Match($c, $pattern)
        if ($m.Success) {
            $forgeHost = ([regex]::Match($m.Value, '(?:github|gitlab|bitbucket|codeberg|sr)\.[a-z]+')).Value.ToLowerInvariant()
            if ($forgeHost -eq 'sr.ht') { $forgeHost = 'git.sr.ht' }
            $owner = $m.Groups[1].Value.ToLowerInvariant()
            $repo = ($m.Groups[2].Value -replace '\.git$', '').ToLowerInvariant()
            return [pscustomobject]@{ Host = $forgeHost; Owner = $owner; Repo = $repo; Url = "https://$forgeHost/$owner/$repo" }
        }
    }
    $null
}
