#Requires -Version 7.0

function New-DFUuid {
    <#
    .SYNOPSIS
        Generates a new random (version 4) UUID with selectable formatting.
    .DESCRIPTION
        Emits a freshly generated version-4 UUID using [guid]::NewGuid(). By default
        the output is lowercase, hyphenated, and unbraced — matching the Unix uuidgen
        tool and the Windows SDK uuidgen.exe default (e.g.
        f47ac10b-58cc-4372-a567-0e02b2c3d479).

        The casing, hyphenation, and brace switches are independent and may be freely
        combined, so all eight format variants are reachable — including the
        registry/COM form via -UpperCase -Braces ({F47AC10B-...}). The -Sdk switch is
        a named preset for the Windows SDK uuidgen default format (lowercase, hyphens,
        no braces) and cannot be combined with the formatting switches.

        This is the DotForge entry point for UUID generation and is also exposed under
        the bare uuidgen alias on every platform. The alias is unconditional: it
        deliberately shadows any native uuidgen so the command always produces the
        same Unix-style string regardless of what is installed on PATH.
    .PARAMETER UpperCase
        Emit the hexadecimal digits in upper case. Defaults to lower case.
    .PARAMETER NoHyphens
        Omit the group-separating hyphens, yielding 32 contiguous hex digits.
        Defaults to including hyphens.
    .PARAMETER Braces
        Wrap the UUID in curly braces ({ }). Defaults to no braces.
    .PARAMETER Sdk
        Produce the Windows SDK uuidgen default format: lowercase, hyphenated, no
        braces. Equivalent to the unparameterized default; provided as a named,
        self-documenting preset. Cannot be combined with the formatting switches.
    .EXAMPLE
        New-DFUuid
        Outputs a new lowercase, hyphenated v4 UUID string (e.g. f47ac10b-...-c3d479).
    .EXAMPLE
        New-DFUuid -UpperCase -Braces
        Outputs the registry/COM form, e.g. {F47AC10B-58CC-4372-A567-0E02B2C3D479}.
    .EXAMPLE
        New-DFUuid -NoHyphens
        Outputs 32 contiguous lowercase hex digits with no separators.
    .EXAMPLE
        New-DFUuid -Sdk
        Outputs the Windows SDK uuidgen default format (lowercase, hyphens, no braces).
    .EXAMPLE
        uuidgen
        The uuidgen alias always resolves here, yielding Unix-style output.
    .OUTPUTS
        System.String — a version-4 UUID formatted per the supplied switches.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Custom')]
    [OutputType([string])]
    param(
        [Parameter(ParameterSetName = 'Custom')]
        [switch]$UpperCase,

        [Parameter(ParameterSetName = 'Custom')]
        [switch]$NoHyphens,

        [Parameter(ParameterSetName = 'Custom')]
        [switch]$Braces,

        [Parameter(ParameterSetName = 'Sdk')]
        [switch]$Sdk
    )

    # Start from the canonical 'D' form (lowercase, hyphens, no braces) and apply
    # each independent switch. In the 'Sdk' parameter set the formatting switches
    # cannot be bound, so they stay $false and the canonical form is returned as-is.
    $s = [guid]::NewGuid().ToString('D')
    if ($NoHyphens) { $s = $s -replace '-', '' }
    if ($UpperCase) { $s = $s.ToUpperInvariant() }
    if ($Braces)    { $s = "{$s}" }
    $s
}

# Always alias `uuidgen` to our generator so it behaves like the Unix command on
# every platform, deliberately shadowing any native uuidgen (e.g. the Windows SDK
# binary) for consistent, predictable output.
Set-Alias -Name uuidgen -Value New-DFUuid -Scope Global -Force
