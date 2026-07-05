#Requires -Version 7.0

function Test-DFCategoryDbSchema {
    <#
    .SYNOPSIS
        Validates a merged category-db document against the trifle discovery
        schema. Returns $true if valid; populates -Errors with any violations.
    .DESCRIPTION
        Checks structural shape only: schemaVersion, taxonomy vocabularies,
        and per-tool required fields / closed-vocabulary membership. Does not
        check cross-references (relatedTo/alternativeTo pointing at real keys)
        — that is intentionally out of scope, same as Test-DFToolSchema.
    .PARAMETER Database
        The parsed category-db document (schemaVersion, taxonomy, tools).
    .PARAMETER Errors
        Reference to an array populated with violation messages. Empty when
        validation passes.
    .OUTPUTS
        [bool] - $true if valid, $false if any violations found.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Database,
        [ref]$Errors
    )

    $errs = [System.Collections.Generic.List[string]]::new()

    function PSProp ([PSCustomObject]$obj, [string]$key) {
        if ($null -eq $obj) { return $null }
        $p = $obj.PSObject.Properties[$key]
        if ($p) { return $p.Value } else { return $null }
    }

    if (-not (PSProp $Database 'schemaVersion')) { $errs.Add('Missing required field: schemaVersion') }
    elseif ((PSProp $Database 'schemaVersion') -ne 1) { $errs.Add("Unsupported schemaVersion '$($Database.schemaVersion)' — expected 1") }

    $taxonomy = PSProp $Database 'taxonomy'
    $functionVocab = @(PSProp $taxonomy 'function')
    $worksWithVocab = @(PSProp $taxonomy 'worksWith')
    if (-not $functionVocab -or $functionVocab.Count -eq 0) { $errs.Add('taxonomy.function must be a non-empty array') }
    if (-not $worksWithVocab -or $worksWithVocab.Count -eq 0) { $errs.Add('taxonomy.worksWith must be a non-empty array') }

    $tools = PSProp $Database 'tools'
    if (-not $tools) {
        $errs.Add('Missing required field: tools')
    } else {
        $validInterfaces = @('cli', 'tui', 'gui')
        foreach ($prop in $tools.PSObject.Properties) {
            $key = $prop.Name
            $entry = $prop.Value

            $function = @(PSProp $entry 'function')
            if (-not $function -or $function.Count -eq 0) {
                $errs.Add("$key`: function must be a non-empty array")
            } else {
                foreach ($f in $function) {
                    if ($f -notin $functionVocab) { $errs.Add("$key`: unknown function value '$f'") }
                }
            }

            $worksWith = @(PSProp $entry 'worksWith')
            foreach ($w in $worksWith) {
                if ($w -notin $worksWithVocab) { $errs.Add("$key`: unknown worksWith value '$w'") }
            }

            $interface = PSProp $entry 'interface'
            if (-not $interface) { $errs.Add("$key`: missing required field interface") }
            elseif ($interface -notin $validInterfaces) { $errs.Add("$key`: invalid interface '$interface'. Valid: $($validInterfaces -join ', ')") }

            $popularity = PSProp $entry 'popularity'
            if ($null -ne $popularity -and ($popularity -lt 0 -or $popularity -gt 3)) {
                $errs.Add("$key`: popularity must be 0-3, got '$popularity'")
            }
        }
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
