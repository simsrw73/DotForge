#Requires -Version 7.0

function Select-DFProcess {
    <#
    .SYNOPSIS
        Fuzzy-searches running processes and returns the selected process object(s).
    .PARAMETER Multi
        Allow selecting multiple processes at once.
    .EXAMPLE
        Select-DFProcess
    .EXAMPLE
        fps -Multi
    #>
    [CmdletBinding()]
    param(
        [switch]$Multi
    )
    Invoke-DFPicker `
        -List    { Get-Process | Sort-Object CPU -Descending |
                   ForEach-Object { '{0,-35} {1,7} {2,8:F1} {3,10}' -f $_.Name, $_.Id, $_.CPU, [math]::Round($_.WorkingSet / 1MB) } } `
        -Header  'Select process  [Enter to output object]' `
        -Preview 'pwsh -NoProfile -NonInteractive -Command "Get-Process -Id {2} | Format-List *" 2>nul' `
        -Multi:$Multi `
        -Parse   {
            $parts = ($_ -split '\s+').Where({ $_ })
            Get-Process -Id ([int]$parts[1]) -ErrorAction Ignore
        }
}
Set-Alias -Name fps -Value Select-DFProcess -Scope Global -Force

function Get-DFTopProcess {
    <#
    .SYNOPSIS
        Lists the top processes sorted by CPU or memory usage.
    .PARAMETER By
        Sort processes by CPU (default) or Memory.
    .PARAMETER Count
        Number of processes to display. Defaults to 20.
    .EXAMPLE
        Get-DFTopProcess
    .EXAMPLE
        top -By Memory -Count 10
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('CPU', 'Memory')]
        [string]$By = 'CPU',
        [int]$Count = 20
    )
    $sortProp = if ($By -eq 'Memory') { 'WorkingSet' } else { 'CPU' }
    Get-Process |
        Sort-Object $sortProp -Descending |
        Select-Object -First $Count -Property Name, Id,
            @{N = 'CPU(s)';  E = { [math]::Round($_.CPU, 2) }},
            @{N = 'Mem(MB)'; E = { [math]::Round($_.WorkingSet / 1MB) }} |
        Format-Table -AutoSize
}
Set-Alias -Name top -Value Get-DFTopProcess -Scope Global -Force
