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
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
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
function Get-DFWhich {
    <#
    .SYNOPSIS
        Returns the full path of an executable on the PATH (which equivalent).
    .PARAMETER Name
        Name of the executable to locate.
    .PARAMETER All
        Return every matching executable on PATH, in PATH order, instead of just
        the first.
    .DESCRIPTION
        Finds an executable on PATH, as Get-Command -CommandType Application does,
        and returns only its full path. Without -All it returns the first match in
        PATH order, which is the one that runs when you type the name. Use -All to
        list every match, including shadowed copies, to diagnose PATH ordering.
        Matches any extension in PATHEXT (.exe, .cmd, .bat, ...). Aliases and
        functions are not considered; use Get-Command for those. Returns nothing
        when there is no match.
    .EXAMPLE
        Get-DFWhich git

        Returns the full path of the git executable found first on PATH.
    .EXAMPLE
        which python -All

        Returns all python executables on PATH using the which alias, useful for
        diagnosing which interpreter would be used.
    .OUTPUTS
        System.String — the full path of the matching executable(s).
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Name,
        [switch]$All
    )
    process {
        # Get-Command -CommandType Application already returns every PATH match,
        # in PATH order, with or without -All, so take the first one ourselves.
        $found = Get-Command -Name $Name -CommandType Application -ErrorAction Ignore |
            Select-Object -ExpandProperty Source
        if ($All) { $found } else { $found | Select-Object -First 1 }
    }
}
function Open-DFItem {
    <#
    .SYNOPSIS
        Opens a file or URL using the system default application (open equivalent).
    .PARAMETER Path
        One or more file paths or URLs to open.
    .DESCRIPTION
        Provides a familiar open command consistent with macOS and Linux
        conventions. Each path is opened with the OS-registered default handler:
        files and directories through Invoke-Item (so wildcards work), and URLs
        (anything starting with scheme://) through Start-Process. A path that
        doesn't exist writes a non-terminating error and the rest still open.
    .EXAMPLE
        Open-DFItem report.pdf

        Opens report.pdf in the default PDF viewer.
    .EXAMPLE
        open https://example.com

        Opens the URL in the default browser using the open alias.
    .OUTPUTS
        None
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    process {
        foreach ($p in $Path) {
            # Invoke-Item reads 'https:' as a PowerShell drive name and fails, so a
            # URI scheme goes to the shell's protocol handler instead.
            if ($p -match '^[a-z][a-z0-9+.-]+://') { Start-Process -FilePath $p }
            else { Invoke-Item $p }
        }
    }
}
