#Requires -Version 7.0

function Test-DFToolSchema {
    <#
    .SYNOPSIS
        Validates a tool PSCustomObject against the DotForge tool schema.
        Returns $true if valid; populates -Errors with any violation messages.
    .DESCRIPTION
        Private validator for tool JSON records. Checks required fields and valid enum values.
        Errors are collected into a list and returned via the -Errors reference parameter.
    .PARAMETER Tool
        The tool PSCustomObject to validate (typically parsed from JSON).
    .PARAMETER Errors
        Reference to an array that will be populated with validation error messages.
        If validation passes, this array will be empty.
    .OUTPUTS
        [bool] - $true if valid, $false if any violations found.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [ref]$Errors
    )

    $errs = [System.Collections.Generic.List[string]]::new()

    # Helper: safely read a property from a PSCustomObject without throwing under StrictMode
    function PSProp ([PSCustomObject]$obj, [string]$key) {
        if ($null -eq $obj) { return $null }
        $p = $obj.PSObject.Properties[$key]
        if ($p) { return $p.Value } else { return $null }
    }

    # Required fields
    if (-not (PSProp $Tool 'name'))       { $errs.Add("Missing required field: name") }
    if (-not (PSProp $Tool 'executable')) { $errs.Add("Missing required field: executable") }

    # xdg.method valid values
    $validMethods = @('default', 'env', 'config', 'wrapper', 'manual')
    $xdgMethod = PSProp (PSProp $Tool 'xdg') 'method'
    if ($xdgMethod -and $xdgMethod -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$xdgMethod'. Valid: $($validMethods -join ', ')")
    }

    $validTypes = @('static', 'dynamic')
    $completionsObj  = PSProp $Tool 'completions'
    $completionsType = PSProp $completionsObj 'type'
    if ($completionsType -and $completionsType -notin $validTypes) {
        $errs.Add("Invalid completions.type '$completionsType'. Valid: $($validTypes -join ', ')")
    }

    $completionsCommand = PSProp $completionsObj 'command'
    if ($completionsType -eq 'dynamic' -and -not $completionsCommand) {
        $errs.Add("completions.type 'dynamic' requires completions.command")
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
