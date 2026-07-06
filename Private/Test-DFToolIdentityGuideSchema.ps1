#Requires -Version 7.0

function Test-DFToolIdentityGuideSchema {
    <#
    .SYNOPSIS
        Validates a merged tool-identity-guide document. Returns $true if
        valid; populates -Errors with any violations.
    .DESCRIPTION
        Checks structural shape (schemaVersion, per-tool packages/linkedVia)
        plus one cross-tool invariant: no (source, packageId) pair may be
        claimed by more than one tool key — that would mean the guide itself
        contradicts the safety property it exists to provide.
    .PARAMETER Database
        The parsed tool-identity-guide document (schemaVersion, tools).
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

    $tools = PSProp $Database 'tools'
    $validLinkedVia = @('repo', 'homepage', 'curated')
    $seenPairs = @{}

    if (-not $tools) {
        $errs.Add('Missing required field: tools')
    } else {
        foreach ($prop in $tools.PSObject.Properties) {
            $key = $prop.Name
            $entry = $prop.Value

            $packages = PSProp $entry 'packages'
            $packageProps = $packages ? @($packages.PSObject.Properties) : @()
            if ($packageProps.Count -eq 0) {
                $errs.Add("$key`: packages must be a non-empty object")
            } else {
                foreach ($pkgProp in $packageProps) {
                    $pairKey = "$($pkgProp.Name.ToLowerInvariant()):$(([string]$pkgProp.Value).ToLowerInvariant())"
                    if ($seenPairs.ContainsKey($pairKey)) {
                        $errs.Add("$pairKey claimed by both '$($seenPairs[$pairKey])' and '$key'")
                    } else {
                        $seenPairs[$pairKey] = $key
                    }
                }
            }

            $linkedVia = PSProp $entry 'linkedVia'
            if (-not $linkedVia) { $errs.Add("$key`: missing required field linkedVia") }
            elseif ($linkedVia -notin $validLinkedVia) { $errs.Add("$key`: invalid linkedVia '$linkedVia'. Valid: $($validLinkedVia -join ', ')") }

            $repoProp = $entry.PSObject.Properties['repo']
            if ($repoProp -and -not $repoProp.Value) { $errs.Add("$key`: repo, when present, must be a non-empty string") }
        }
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
