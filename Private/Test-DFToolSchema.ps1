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

    # executableExclude: glob patterns of install locations to skip.
    # Read the property directly: returning it through PSProp would unroll a
    # one-element array into a bare string and fail the array check.
    $exclude = $Tool.PSObject.Properties['executableExclude']?.Value
    if ($null -ne $exclude -and ($exclude -isnot [array] -or @($exclude | Where-Object { $_ -isnot [string] }).Count)) {
        $errs.Add('executableExclude must be an array of strings')
    }

    # scoopBucket: { name; url } naming a third-party scoop bucket.
    $bucket = PSProp $Tool 'scoopBucket'
    if ($null -ne $bucket -and (-not (PSProp $bucket 'name') -or -not (PSProp $bucket 'url'))) {
        $errs.Add('scoopBucket must be an object with non-empty name and url')
    }

    # roles: an object keyed by role name; priority is an integer and optIn is a boolean when present.
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
                $optIn = PSProp $r.Value 'optIn'
                if ($null -ne $optIn -and $optIn -isnot [bool]) {
                    $errs.Add("roles.$($r.Name).optIn must be a boolean")
                }
            }
        }
    }

    if ($Errors) { $Errors.Value = $errs.ToArray() }
    return $errs.Count -eq 0
}
