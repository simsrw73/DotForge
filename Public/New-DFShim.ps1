#Requires -Version 7.0

function New-DFShim {
    <#
    .SYNOPSIS
        Creates a .cmd shim that forwards invocations to a target executable,
        first changing the working directory to the executable's own directory.
    .DESCRIPTION
        Generates a Windows .cmd batch file in the shims directory that, when
        invoked, changes to the executable's own directory then runs it with all
        forwarded arguments and correctly propagates the exit code. Put the shims
        directory on $PATH once and create shims as needed.
        Accepts a DotForge tool name (DB lookup) or an explicit -Target path.
    .PARAMETER Target
        Path to the target executable. Positional — can be passed without the
        parameter name. Bypasses tool DB lookup. When -Name is omitted, the shim
        name is derived from the target's basename (without extension).
    .PARAMETER Name
        Shim filename (without .cmd extension). When -Target is omitted, also
        used as the DotForge tool name to look up the executable path in the registry.
        Optional when -Target is given; derived from the target's basename if omitted.
    .PARAMETER ShimsPath
        Directory where the shim is written. Defaults to $DFConfig['ShimsPath'],
        then $HOME\.local\bin.
    .PARAMETER Force
        Overwrite an existing shim without error.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    .EXAMPLE
        New-DFShim 'C:\tools\grep\grep.exe'
        Creates $HOME\.local\bin\grep.cmd; name derived from the executable basename.
    .EXAMPLE
        New-DFShim -Name ripgrep
        Creates $HOME\.local\bin\ripgrep.cmd pointing at the ripgrep executable
        found via the DotForge tool registry. Warns if $HOME\.local\bin is not on PATH.
    .EXAMPLE
        New-DFShim 'C:\tools\myapp\myapp.exe' -Name myapp
        Creates a shim with an explicit name, bypassing name derivation.
    .EXAMPLE
        New-DFShim 'C:\tools\myapp\myapp.exe' -Force
        Overwrites an existing shim.
    .EXAMPLE
        New-DFShim -Name ripgrep -WhatIf
        Shows what would be created without writing any file.
    .OUTPUTS
        None
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Target,

        [string]$Name,

        [string]$ShimsPath,

        [switch]$Force,

        [string]$ToolsPath
    )

    # 0. Derive Name from Target basename if not provided; error if neither given
    if ($Target -and -not $Name) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($Target)
    } elseif (-not $Target -and -not $Name) {
        Write-Error 'DotForge: Provide -Target (path to executable) or -Name (tool registry lookup).'
        return
    }

    # 1. Resolve shims directory
    $shimsDir = if ($ShimsPath) {
        $ShimsPath
    # Test the value, not the variable's existence: `$DFConfig = $null` leaves the
    # variable defined, and indexing into it throws "Cannot index into a null array".
    } elseif ($null -ne $Global:DFConfig -and $Global:DFConfig['ShimsPath']) {
        $Global:DFConfig['ShimsPath']
    } else {
        Join-Path $HOME '.local' 'bin'
    }

    # 2. Create directory (idempotent)
    New-DFDirectory $shimsDir

    # 3. PATH check
    $normalizedShims = [IO.Path]::GetFullPath($shimsDir).TrimEnd('\', '/')
    $onPath = $Env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ } |
        Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') -eq $normalizedShims }
    if (-not $onPath) {
        Write-Warning "DotForge: '$shimsDir' is not on PATH — shims won't be invocable until it is added"
    }

    # 4. Resolve target executable
    $resolvedTarget = $null
    if ($Target) {
        if (-not (Test-Path $Target -PathType Leaf)) {
            Write-Error "DotForge: Target '$Target' does not exist or is not a file"
            return
        }
        $resolvedTarget = $Target
    } else {
        $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
        $db = Import-DFToolDb @dbArgs
        if (-not $db.ContainsKey($Name)) {
            Write-Error "DotForge: Tool '$Name' not found in registry. Use -Target to specify the executable path."
            return
        }
        $executable = $db[$Name].executable
        $found = Get-Command $executable -ErrorAction Ignore
        if (-not $found) {
            Write-Error "DotForge: Tool '$Name' executable '$executable' not found on PATH. Is the tool installed?"
            return
        }
        $resolvedTarget = $found.Source
    }

    # 5. App directory (working dir for the shim)
    $appDir = Split-Path -Parent $resolvedTarget

    # 6. Shim existence check
    $shimPath = Join-Path $shimsDir "$Name.cmd"
    if ((Test-Path $shimPath) -and -not $Force -and -not $WhatIfPreference) {
        Write-Error "DotForge: Shim '$shimPath' already exists. Use -Force to overwrite."
        return
    }

    # 7. Write shim
    if ($PSCmdlet.ShouldProcess($shimPath, 'Create shim')) {
        $lines = @(
            '@echo off'
            'setlocal'
            "cd /d `"$appDir`""
            "`"$resolvedTarget`" %*"
            'set "_exit=%ERRORLEVEL%"'
            'endlocal & exit /b %_exit%'
        )
        Set-Content -Path $shimPath -Value ($lines -join "`r`n") -Encoding ASCII -NoNewline
        Write-Verbose "DotForge: shim created → $shimPath"
    }
}
