#Requires -Version 7.0

$script:DFToolAvailability = @{}

function Test-DFToolAvailable {
    <#
    .SYNOPSIS
        Checks whether a tool's executable or module is available; "available" is remembered for the session.
    .DESCRIPTION
        Wraps Get-Command (exe-type tools) / Get-Module -ListAvailable
        (module-type tools) with a session-scoped cache keyed by type and
        name. Only a positive answer is remembered: an available tool is probed
        once per session, but a missing one is probed again on every call,
        because an earlier tool can put it on PATH mid-load (fnm puts node,
        npm and inshellisense's `is` on PATH only when its companion runs) and
        an install can add it mid-session. A missing tool costs one lookup per
        call, and only missing tools pay it.
    .PARAMETER Executable
        The executable name (exe-type tools) or module name (module-type
        tools) to check.
    .PARAMETER Type
        'exe' or 'module'. Defaults to 'exe'.
    .PARAMETER Force
        Bypass the cache and re-probe.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'ripgrep.exe'
        Returns $true if ripgrep.exe is on PATH.
    .EXAMPLE
        Test-DFToolAvailable -Executable 'PSFzf' -Type 'module'
        Returns $true if the PSFzf module is installed.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [ValidateSet('exe', 'module')]
        [string]$Type = 'exe',

        [switch]$Force
    )

    $key = "$Type|$Executable"
    if (-not $Force -and $script:DFToolAvailability.ContainsKey($key)) {
        return $script:DFToolAvailability[$key]
    }

    $available = [bool]$(if ($Type -eq 'module') {
        Get-Module -Name $Executable -ListAvailable -ErrorAction Ignore
    } else {
        Get-Command $Executable -ErrorAction Ignore
    })

    # Never remember "not installed": see .DESCRIPTION.
    if ($available) { $script:DFToolAvailability[$key] = $true }
    return $available
}
