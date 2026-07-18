#Requires -Version 7.0

# Phase D closed-vocabulary loader: the coarse domain axis (build/categories/
# domains.jsonc) + the existing trifle function/worksWith taxonomy. See spec.

function Import-DFPackageUniverseVocab {
    <#
    .SYNOPSIS
        Loads the closed classification vocabulary { Domain; Function; WorksWith }
        from the coarse domains.jsonc and the trifle taxonomy JSON. JSONC line/
        block comments stripped (line comments anchored to line start).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DomainsPath, [Parameter(Mandatory)][string]$TaxonomyPath)

    function Read-Jsonc([string]$Path) {
        $t = Get-Content -Raw -Path $Path
        $t = [regex]::Replace($t, '(?m)^\s*//.*$', '')
        $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
        $t | ConvertFrom-Json
    }
    $dom = Read-Jsonc $DomainsPath
    $tax = (Read-Jsonc $TaxonomyPath).taxonomy
    [pscustomobject]@{
        Domain    = @($dom.domain)
        Function  = @($tax.function)
        WorksWith = @($tax.worksWith)
    }
}

function Test-DFPackageUniverseVocabValue {
    <#
    .SYNOPSIS
        True when $Value is in the closed $Vocab list (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Value, [AllowEmptyCollection()][string[]]$Vocab)
    if (-not $Value) { return $false }
    [bool](@($Vocab) -contains $Value.ToLowerInvariant() -or @($Vocab | ForEach-Object { $_.ToLowerInvariant() }) -contains $Value.ToLowerInvariant())
}
