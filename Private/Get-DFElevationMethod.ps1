#Requires -Version 7.2

function Test-DFWindowsSudoInline {
    <#
    .SYNOPSIS
        Whether Windows' built-in sudo is on in inline mode (Settings > System > For developers) and on PATH.
    .DESCRIPTION
        Windows' sudo is off until the user turns it on; only inline mode runs
        the command in this console, so its output can be read.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $enabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -Name Enabled -ErrorAction Ignore).Enabled
    $enabled -eq 3 -and [bool](Get-Command sudo.exe -CommandType Application -ErrorAction Ignore)
}

function Get-DFElevationMethod {
    <#
    .SYNOPSIS
        How a command that needs administrator rights gets them in this shell.
    .DESCRIPTION
        In order: the shell is already elevated (Direct); an elevator tool (the
        elevator role, e.g. gsudo) that is installed or installed earlier in the
        same plan (Elevator); Windows' sudo in inline mode (WindowsSudo); a
        separate administrator window through Start-Process -Verb RunAs (RunAs).
        The last two need a person to answer the admin prompt, so a
        non-interactive host gets Unavailable instead. An elevator is used
        even then, as installs always have.
    .PARAMETER ToolDb
        Name -> tool record; the elevator role's members come from it.
    .PARAMETER IsAvailable
        { param($record) } -> whether that tool is installed now.
    .PARAMETER Planned
        Tools installed earlier in the same plan.
    .OUTPUTS
        PSCustomObject: Method (Direct, Elevator, WindowsSudo, RunAs, Unavailable), Executable,
        Detail, and Tool (the elevator's name, for Elevator).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$ToolDb = @{},
        [scriptblock]$IsAvailable = { param($t) Test-DFToolAvailable -Executable $t.executable -Type $t.type },
        [string[]]$Planned = @()
    )
    $method = { param($name, $exe, $detail, $tool) [pscustomobject]@{ Method = $name; Executable = $exe; Detail = $detail; Tool = $tool } }
    if (Test-DFElevated) { return & $method 'Direct' $null 'already elevated' }
    $elevators = @($ToolDb.Values | Where-Object { $_.roles.PSObject.Properties['elevator'] } | Sort-Object name)
    $elevator = @($elevators | Where-Object { & $IsAvailable $_ }) + @($elevators | Where-Object { $_.name -in $Planned }) | Select-Object -First 1
    if ($elevator) { return & $method 'Elevator' $elevator.executable "through $($elevator.name)" $elevator.name }
    if (-not (Test-DFInteractiveHost)) { return & $method 'Unavailable' $null 'no one to answer the admin prompt' }
    if (Test-DFWindowsSudoInline) { return & $method 'WindowsSudo' 'sudo' "through Windows' sudo" }
    & $method 'RunAs' $null 'in a separate administrator window (exit code only)'
}
