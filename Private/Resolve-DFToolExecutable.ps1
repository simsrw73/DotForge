#Requires -Version 7.2

function Resolve-DFToolExecutable {
    <#
    .SYNOPSIS
        Returns the full path of a tool's executable, skipping copies its executableExclude patterns rule out.
    .DESCRIPTION
        Walks Get-Command <executable> -All (PATH order) and returns the first path
        that matches none of the tool's executableExclude globs (case-insensitive),
        or $null when none qualifies. Used only to expand ${DF_TOOL_EXE}; tool
        detection (Test-DFToolAvailable) ignores the exclusions.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $exclude = @($Tool.PSObject.Properties['executableExclude']?.Value)
    foreach ($cmd in @(Get-Command $Tool.executable -All -CommandType Application -ErrorAction Ignore)) {
        $path = $cmd.Source
        if (-not $path) { continue }
        $skip = $false
        foreach ($pattern in $exclude) { if ($pattern -and $path -like $pattern) { $skip = $true; break } }
        if (-not $skip) { return $path }
    }
}

function ConvertTo-DFToolExePathToken {
    <#
    .SYNOPSIS
        The value ${DF_TOOL_EXE} expands to: the tool's resolved path with forward slashes, quoted when it holds a space, else its bare name.
    .DESCRIPTION
        Forward slashes keep sh -c based callers (git's pager handling) from
        treating backslashes as escapes; Windows programs accept them. With no
        qualifying copy, the executable name without .exe, which leaves the
        choice to PATH as before.
    .PARAMETER Tool
        The normalized tool record.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $path = Resolve-DFToolExecutable -Tool $Tool
    if (-not $path) { return [IO.Path]::GetFileNameWithoutExtension($Tool.executable) }
    $path = $path -replace '\\', '/'
    if ($path -match '\s') { "`"$path`"" } else { $path }
}
