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

    # Required fields
    if (-not $Tool.name)       { $errs.Add("Missing required field: name") }
    if (-not $Tool.executable) { $errs.Add("Missing required field: executable") }

    # xdg.method valid values
    $validMethods = @('default', 'env', 'config', 'wrapper', 'manual')
    if ($Tool.xdg -and $Tool.xdg.method -and $Tool.xdg.method -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$($Tool.xdg.method)'. Valid: $($validMethods -join ', ')")
    }

    # completions.type valid values
    $validTypes = @('static', 'dynamic')
    if ($Tool.completions -and $Tool.completions.type -and
        $Tool.completions.type -notin $validTypes) {
        $errs.Add("Invalid completions.type '$($Tool.completions.type)'. Valid: $($validTypes -join ', ')")
    }

    # dynamic completions require command
    if ($Tool.completions.type -eq 'dynamic' -and -not $Tool.completions.command) {
        $errs.Add("completions.type 'dynamic' requires completions.command")
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
