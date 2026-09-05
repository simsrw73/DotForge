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
        reference it. Install-DFTool calls this with -Force immediately after
        a successful install, so a Register-DFTool call right after installing
        a tool still picks it up. A tool made available by any other means
        mid-session (e.g. a user manually editing PATH) is not detected until
        -Force is passed or a new session starts.
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
