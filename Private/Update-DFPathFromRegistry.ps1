#Requires -Version 7.2

function Get-DFRegistryPath {
    <#
    .SYNOPSIS
        Returns the persisted Machine and User PATH (what a new shell would get).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join [IO.Path]::PathSeparator
}

function Update-DFPathFromRegistry {
    <#
    .SYNOPSIS
        Appends PATH entries an installer wrote to the registry, so this shell finds new tools without a restart.
    .DESCRIPTION
        Only entries the session lacks are added, at the end, through
        Add-DFToPath. Nothing is removed or reordered, so session-only entries
        (fnm's multishell folder, a venv) survive.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $sep = [IO.Path]::PathSeparator
    $have = @($Env:Path -split $sep | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
    foreach ($p in (Get-DFRegistryPath) -split $sep) {
        $p = [Environment]::ExpandEnvironmentVariables($p.Trim())
        if ($p -and $p.TrimEnd('\', '/') -notin $have) {
            Add-DFToPath $p
            $have += $p.TrimEnd('\', '/')
        }
    }
}
