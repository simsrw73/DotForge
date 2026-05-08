#Requires -Version 7.0

function New-DFFile {
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
