#Requires -Version 7.0

function New-DFFile {
    <#
    .SYNOPSIS
        Creates a file or updates its timestamp if it already exists (touch equivalent).
    .PARAMETER Path
        One or more file paths to create or touch.
    .DESCRIPTION
        Mimics the Unix touch command: creates an empty file if it doesn't exist,
        or updates LastWriteTime to the current time if it does. Accepts multiple
        paths and pipeline input.
    .EXAMPLE
        New-DFFile readme.md
        Creates readme.md or updates its timestamp if it already exists.
    .EXAMPLE
        touch foo.txt bar.txt
        Touches multiple files at once using the touch alias.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) {
            if (Test-Path $p) {
                (Get-Item $p).LastWriteTime = Get-Date
            } else {
                New-Item -ItemType File -Path $p | Out-Null
            }
        }
    }
}
Set-Alias -Name touch -Value New-DFFile -Scope Global -Force

function Get-DFWhich {
    <#
    .SYNOPSIS
        Returns the full path of an executable on the PATH (which equivalent).
    .PARAMETER Name
        Name of the executable to locate.
    .PARAMETER All
        Return all matching executables instead of just the first.
    .DESCRIPTION
        Wraps Get-Command -CommandType Application to find executables on PATH,
        returning only the Source path rather than the full command object. Use
        -All to surface shadowed executables and diagnose PATH ordering issues.
    .EXAMPLE
        Get-DFWhich git
        Returns the full path of the git executable found first on PATH.
    .EXAMPLE
        which python -All
        Returns all python executables on PATH using the which alias, useful for
        diagnosing which interpreter would be used.
    .OUTPUTS
        System.String — the full path of the matching executable(s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Name,
        [switch]$All
    )
    process {
        $params = @{ Name = $Name; CommandType = 'Application'; ErrorAction = 'Ignore' }
        if ($All) { $params.All = $true }
        Get-Command @params | Select-Object -ExpandProperty Source
    }
}
Set-Alias -Name which -Value Get-DFWhich -Scope Global -Force

function Open-DFItem {
    <#
    .SYNOPSIS
        Opens a file or URL using the system default application (open equivalent).
    .PARAMETER Path
        One or more file paths or URLs to open.
    .DESCRIPTION
        Wraps Invoke-Item to provide a familiar open command consistent with macOS
        and Linux conventions. Accepts files, directories, and URLs; each is opened
        with the OS-registered default handler.
    .EXAMPLE
        Open-DFItem report.pdf
        Opens report.pdf in the default PDF viewer.
    .EXAMPLE
        open https://example.com
        Opens the URL in the default browser using the open alias.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) { Invoke-Item $p }
    }
}
Set-Alias -Name open -Value Open-DFItem -Scope Global -Force
