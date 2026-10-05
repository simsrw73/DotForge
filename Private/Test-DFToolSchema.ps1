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
        <#
        .SYNOPSIS
            StrictMode-safe property read: $obj.<key>, or $null when $obj or the property is absent.
        .PARAMETER obj
            The object to read from; may be $null.
        .PARAMETER key
            The property name.
        #>
        if ($null -eq $obj) { return $null }
        $p = $obj.PSObject.Properties[$key]
        if ($p) { return $p.Value } else { return $null }
    }

    # Required fields
    if (-not (PSProp $Tool 'name'))       { $errs.Add("Missing required field: name") }
    if (-not (PSProp $Tool 'executable')) { $errs.Add("Missing required field: executable") }

    # type valid values
    $validToolTypes = @('exe', 'module')
    $toolType = PSProp $Tool 'type'
    if ($toolType -and $toolType -notin $validToolTypes) {
        $errs.Add("Invalid type '$toolType'. Valid: $($validToolTypes -join ', ')")
    }

    # xdg.method valid values
    $validMethods = @('default', 'env', 'config', 'wrapper', 'manual')
    $xdgMethod = PSProp (PSProp $Tool 'xdg') 'method'
    if ($xdgMethod -and $xdgMethod -notin $validMethods) {
        $errs.Add("Invalid xdg.method '$xdgMethod'. Valid: $($validMethods -join ', ')")
    }

    # roles: an object keyed by role name; each priority, when present, is an integer.
    $roles = PSProp $Tool 'roles'
    if ($null -ne $roles) {
        if ($roles -isnot [pscustomobject]) {
            $errs.Add('roles must be an object keyed by role name')
        } else {
            foreach ($r in $roles.PSObject.Properties) {
                $priority = PSProp $r.Value 'priority'
                if ($null -ne $priority -and $priority -isnot [int] -and $priority -isnot [long]) {
                    $errs.Add("roles.$($r.Name).priority must be an integer")
                }
            }
        }
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
