#Requires -Version 7.0

function Select-DFProcess {
    <#
    .SYNOPSIS
        Fuzzy-searches running processes and returns the selected process object(s).
    .PARAMETER Multi
        Allow selecting multiple processes at once.
    .DESCRIPTION
        Lists all running processes sorted by CPU descending in fzf with a preview
        pane showing Format-List details. Returns the full process object(s) so
        results can be piped to Stop-Process, Get-Process, or other cmdlets.
    .EXAMPLE
        Select-DFProcess
        Opens fzf over running processes; returns the selected process object.
    .EXAMPLE
        fps -Multi | Stop-Process
        Selects multiple processes in fzf and stops them all using the fps alias.
    .OUTPUTS
        System.Diagnostics.Process — the selected process object(s).
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
    .DESCRIPTION
        Provides a quick snapshot of resource-consuming processes similar to the
        Unix top command. Outputs a table with name, PID, CPU seconds, and memory
        in MB for easy scanning without opening Task Manager.
    .EXAMPLE
        Get-DFTopProcess
        Lists the top 20 processes by CPU usage.
    .EXAMPLE
        top -By Memory -Count 10
        Lists the top 10 processes by memory consumption using the top alias.
    .OUTPUTS
        PSCustomObject — process records with Name, Id, CPU(s), and Mem(MB) columns.
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
            @{N = 'Mem(MB)'; E = { [math]::Round($_.WorkingSet / 1MB) }}
}
Set-Alias -Name top -Value Get-DFTopProcess -Scope Global -Force
