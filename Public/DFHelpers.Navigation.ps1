#Requires -Version 7.0

function Set-DFLocationUp {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateRange(1, 99)]
        [int]$Levels = 1
    )
    $path = ('../' * $Levels).TrimEnd('/')
    Set-Location $path
}
Set-Alias -Name up -Value Set-DFLocationUp -Scope Global -Force

function New-DFDirectoryAndSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )
    Ensure-DFDir $Path
    Set-Location $Path
}
Set-Alias -Name mkcd -Value New-DFDirectoryAndSet -Scope Global -Force

function Select-DFLocation {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   {
            if (Get-Command fd -ErrorAction Ignore) {
                fd --type d 2>$null
            } else {
                Get-ChildItem -Recurse -Directory -ErrorAction Ignore |
                    Select-Object -ExpandProperty FullName
            }
        } `
        -Header 'Select directory  [Enter to cd]' `
        -Action { param($dir) Set-Location $dir }
}
Set-Alias -Name fcd -Value Select-DFLocation -Scope Global -Force
