#Requires -Version 7.0
Set-StrictMode -Version Latest

# Author-side conformance library. Dot-sourced by build/Test-DFToolConformance.ps1
# and by tests. NEVER loaded by the DotForge module.
# Requires Expand-DFXdgPath / ConvertTo-DFPath to be dot-sourced first.

$script:DFConfClaimGrammar =
    '^[a-z0-9][a-z0-9._-]*/honors-(xdg|env|config-read|config-content|flag)(:[^/]+)?$'
$script:DFConfKinds = @('env-then-spawn','flag-then-spawn','manual','code')
$script:DFConfSpawnKinds = @('env-then-spawn','flag-then-spawn')
$script:DFConfVerdicts = @('pass','fail','manual','unknown')

function Read-DFConformanceFragment {
    [CmdletBinding()] [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content $Path -Raw
    $stripped = ($raw -split "`n" | ForEach-Object {
        if ($_ -match '^(?<code>(?:[^"]|"[^"]*")*?)//') { $Matches.code } else { $_ }
    }) -join "`n"
    $stripped | ConvertFrom-Json
}

function Expand-DFConformanceToken {
    [CmdletBinding()] [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value,
          [Parameter(Mandatory)][string]$Scratch)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    # Literal string replace (not -replace): $Scratch may contain backslashes that
    # would be interpreted as regex replacement groups.
    $v = $Value.Replace('${SCRATCH}', $Scratch)
    if ($v -cmatch '\$\{XDG_(CONFIG|DATA|STATE|CACHE)_HOME\}') { $v = Expand-DFXdgPath $v }
    $v
}

function Test-DFConformanceDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Fragment)
    $tool = $Fragment.PSObject.Properties['tool']?.Value
    if (-not $tool -or $tool -isnot [string]) {
        throw "DFConformance: fragment missing a string 'tool' field."
    }
    if ($null -eq $Fragment.claims) { throw "DFConformance: '$tool' has no 'claims' array." }
    foreach ($c in $Fragment.claims) {
        if (-not $c.id -or $c.id -cnotmatch $script:DFConfClaimGrammar) {
            throw "DFConformance: claim id '$($c.id)' violates the id grammar."
        }
        $probe = $c.PSObject.Properties['probe']?.Value
        if (-not $probe -or $probe.kind -notin $script:DFConfKinds) {
            throw "DFConformance: claim '$($c.id)' has an unknown probe kind '$($probe.kind)'."
        }
        switch ($probe.kind) {
            { $_ -in $script:DFConfSpawnKinds } {
                $spawn = $probe.PSObject.Properties['spawn']?.Value
                if (-not $spawn) { throw "DFConformance: claim '$($c.id)' ($_) needs a 'spawn' array." }
                $exp = $probe.PSObject.Properties['expect']?.Value
                $set = @('match','notMatch','contains','notContains') |
                    Where-Object { $exp -and $null -ne $exp.PSObject.Properties[$_] }
                if (@($set).Count -ne 1) {
                    throw "DFConformance: claim '$($c.id)' needs exactly one 'expect' rule (got $(@($set).Count))."
                }
            }
            'manual' {
                $probeRetest = $probe.PSObject.Properties['retest']?.Value
                $claimRetest = $c.PSObject.Properties['retest']?.Value
                if (-not $probeRetest -and -not $claimRetest) {
                    throw "DFConformance: manual claim '$($c.id)' needs a 'retest' string."
                }
            }
            'code' {
                $ref = $probe.PSObject.Properties['ref']?.Value
                if (-not $ref) { throw "DFConformance: code claim '$($c.id)' needs a 'ref'." }
            }
        }
    }
}
