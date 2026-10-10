#Requires -Version 7.2

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

    $available = if ($Type -eq 'module') { Test-DFModuleOnPath -Name $Executable } else { Test-DFExecutableOnPath -Name $Executable }

    # Never remember "not installed": see .DESCRIPTION.
    if ($available) { $script:DFToolAvailability[$key] = $true }
    return $available
}

function Test-DFExecutableOnPath {
    <#
    .SYNOPSIS
        Whether an executable is on PATH, by checking its exact candidate filenames in each PATH folder.
    .DESCRIPTION
        A cheaper stand-in for Get-Command when only "is it installed?"
        matters (about half the time per tool at startup). A name with an
        extension is looked up as is; a bare name also tries each PATHEXT
        extension (pipx is pipx.cmd from scoop, pipx.exe from pip). Folders
        that don't exist are skipped. A rooted path is checked directly.
    .PARAMETER Name
        The executable, e.g. 'rg.exe' or 'pipx'.
    .PARAMETER PathValue
        The PATH to search. Default: $Env:Path.
    .PARAMETER PathExt
        Extensions a bare name may have. Default: $Env:PATHEXT.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$PathValue = $Env:Path,
        [string]$PathExt = $Env:PATHEXT
    )
    if ([IO.Path]::IsPathRooted($Name)) { return [IO.File]::Exists($Name) }
    $names = if ([IO.Path]::HasExtension($Name)) { @($Name) }
             else { @($Name) + @("$PathExt" -split ';' | Where-Object { $_ } | ForEach-Object { $Name + $_ }) }
    foreach ($dir in "$PathValue" -split [IO.Path]::PathSeparator) {
        $dir = $dir.Trim().Trim('"')
        if (-not $dir) { continue }
        foreach ($n in $names) {
            if ([IO.File]::Exists([IO.Path]::Combine($dir, $n))) { return $true }
        }
    }
    $false
}

function Test-DFModuleOnPath {
    <#
    .SYNOPSIS
        Whether a PowerShell module is installed, by checking for its folder under each PSModulePath root.
    .DESCRIPTION
        A cheaper stand-in for Get-Module -ListAvailable (about a tenth of the
        time), which also reads every manifest it finds.
    .PARAMETER Name
        The module name.
    .PARAMETER ModulePath
        The module search path. Default: $Env:PSModulePath.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ModulePath = $Env:PSModulePath
    )
    foreach ($root in "$ModulePath" -split [IO.Path]::PathSeparator) {
        $root = $root.Trim().Trim('"')
        if ($root -and [IO.Directory]::Exists([IO.Path]::Combine($root, $Name))) { return $true }
    }
    $false
}
