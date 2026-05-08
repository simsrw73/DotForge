#Requires -Version 7.0

function Invoke-DFHelp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    $helpText = Get-Help $Name -Full | Out-String

    $useColor = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    if ($useColor) {
        $yellow = "`e[1;33m"
        $reset  = "`e[0m"
        foreach ($h in 'SYNOPSIS','DESCRIPTION','PARAMETERS','EXAMPLES','NOTES','RELATED LINKS') {
            $helpText = $helpText -replace "(?m)^($h)", "$yellow`$1$reset"
        }
    }

    $helpText | Invoke-DFWithPager
}
Set-Alias -Name hm -Value Invoke-DFHelp -Scope Global -Force

function Select-DFCommand {
    [CmdletBinding()]
    param(
        [string]$Module = ''
    )
    $gcParams = @{}
    if ($Module) { $gcParams.Module = $Module }

    Invoke-DFPicker `
        -List    { Get-Command @gcParams |
                   ForEach-Object { '{0,-50} {1,-15} {2}' -f $_.Name, $_.CommandType, $_.Source } } `
        -Header  'Select command  [Enter to output name]' `
        -Preview 'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue | Out-String" 2>nul' `
        -Parse   { ($_ -split '\s+')[0] }
}
Set-Alias -Name fcmd -Value Select-DFCommand -Scope Global -Force

function Select-DFVerb {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   { Get-Verb | ForEach-Object { '{0,-20} {1}' -f $_.Group, $_.Verb } } `
        -Header 'Select verb  [Enter to output]' `
        -Parse  { ($_ -split '\s+')[1] }
}
Set-Alias -Name fverb -Value Select-DFVerb -Scope Global -Force

function Select-DFModule {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List   { Get-Module -ListAvailable |
                  ForEach-Object { '{0,-40} {1,-10} {2}' -f $_.Name, $_.Version, $_.Description } } `
        -Header 'Select module  [Enter to output name]' `
        -Parse  { ($_ -split '\s+')[0] }
}
Set-Alias -Name fmod -Value Select-DFModule -Scope Global -Force
