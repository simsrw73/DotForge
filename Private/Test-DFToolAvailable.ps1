#Requires -Version 7.0

$script:DFToolAvailability = @{}

function script:Test-DFToolAvailable {
    <#
    .SYNOPSIS
        Checks whether a tool's executable or module is available, memoized
        per (type, name) for the session.
    .DESCRIPTION
        Wraps Get-Command (exe-type tools) / Get-Module -ListAvailable
        (module-type tools) with a session-scoped cache keyed by type and
        name, so a given tool is probed at most once regardless of how many
        times Register-DFTool runs or how many role-resolution checks
        reference it. Semantics are identical to calling Get-Command/
        Get-Module directly -- this only removes redundant repeat probes.
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

    $script:DFToolAvailability[$key] = $available
    return $available
}
