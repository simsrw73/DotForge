#Requires -Version 7.0

function New-DFFile {
    <#
    .SYNOPSIS
        Creates a file or updates its timestamp if it already exists (touch equivalent).
    .PARAMETER Path
        One or more file paths to create or touch.
    .EXAMPLE
        New-DFFile readme.md
    .EXAMPLE
        touch foo.txt bar.txt
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
    .EXAMPLE
        Get-DFWhich git
    .EXAMPLE
        which python -All
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
    .EXAMPLE
        Open-DFItem report.pdf
    .EXAMPLE
        open https://example.com
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
