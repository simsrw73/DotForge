#Requires -Version 7.0

function Invoke-DFHelp {
    <#
    .SYNOPSIS
        Displays colorized full help for a command, piped through the configured pager.
    .PARAMETER Name
        The name of the command, function, or alias to look up.
    .EXAMPLE
        Invoke-DFHelp Get-ChildItem
    .EXAMPLE
        hm git
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    $helpText = Get-Help $Name -Full | Out-String

    $useColor = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    if ($useColor) {
        $yellow = "`e[1;33m"
        $reset = "`e[0m"
        $helpText = $helpText -creplace '(?m)^([A-Z]{2,}(?: [A-Z]+)*)\r?$', "$yellow`$1$reset"
    }

    $helpText | Invoke-DFWithPager
}
Set-Alias -Name hm -Value Invoke-DFHelp -Scope Global -Force

function Select-DFCommand {
    <#
    .SYNOPSIS
        Fuzzy-searches all available commands and returns the selected command name.
    .PARAMETER Module
        Optional module name to restrict the command list.
    .EXAMPLE
        Select-DFCommand
    .EXAMPLE
        fcmd -Module DotForge
    #>
    [CmdletBinding()]
    param(
        [string]$Module = ''
    )
    $gcParams = @{}
    if ($Module) { $gcParams.Module = $Module }

    Invoke-DFPicker `
        -List { Get-Command @gcParams |
            ForEach-Object { '{0,-50} {1,-15} {2}' -f $_.Name, $_.CommandType, $_.Source } } `
        -Header 'Select command  [Enter to output name]' `
        -Preview 'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue | Out-String" 2>nul' `
        -Parse { ($_ -split '\s+')[0] }
}
Set-Alias -Name fcmd -Value Select-DFCommand -Scope Global -Force

function Select-DFVerb {
    <#
    .SYNOPSIS
        Fuzzy-searches approved PowerShell verbs and returns the selected verb.
    .EXAMPLE
        Select-DFVerb
    .EXAMPLE
        fverb
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List { Get-Verb | ForEach-Object { '{0,-20} {1}' -f $_.Verb, $_.Group } } `
        -Header 'Select verb  [Enter to output]' `
        -Parse { ($_ -split '\s+')[0] }
}
Set-Alias -Name fverb -Value Select-DFVerb -Scope Global -Force

function Select-DFModule {
    <#
    .SYNOPSIS
        Fuzzy-searches all available modules and returns the selected module name.
    .EXAMPLE
        Select-DFModule
    .EXAMPLE
        fmod
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List { Get-Module -ListAvailable |
            ForEach-Object { '{0,-40} {1,-10} {2}' -f $_.Name, $_.Version, $_.Description } } `
        -Header 'Select module  [Enter to output name]' `
        -Parse { ($_ -split '\s+')[0] }
}
Set-Alias -Name fmod -Value Select-DFModule -Scope Global -Force

function Select-DFHelpTopic {
    <#
    .SYNOPSIS
        Fuzzy-searches all available PS help topics and opens the selected topic in Invoke-DFHelp.
    .PARAMETER Category
        Optional. Filters topics by Get-Help category (Cmdlet, Function, HelpFile, Module, etc.).
        No ValidateSet — accepts any string so future PS categories work without a code change.
    .PARAMETER Force
        Bypass the topic list cache and regenerate from Get-Help *.
    .EXAMPLE
        Select-DFHelpTopic
    .EXAMPLE
        fh -Category HelpFile
    .EXAMPLE
        fh -Force
    #>
    [CmdletBinding()]
    param(
        [string]$Category = '',
        [switch]$Force
    )

    $topics = Get-DFHelpTopicList -Force:$Force
    if ($Category) {
        $topics = @($topics | Where-Object { ($_ -split "`t", 2)[1] -eq $Category })
    }

    Invoke-DFPicker `
        -List      { $topics }.GetNewClosure() `
        -Delimiter "`t" `
        -WithNth   '1' `
        -Header    'Browse help topics  [Enter to view full help]' `
        -Preview   'pwsh -NoProfile -NonInteractive -Command "Get-Help {1} -ErrorAction SilentlyContinue | Out-String" 2>nul' `
        -Parse     { ($_ -split "`t", 2)[0] } `
        -Action    { param($topic) Invoke-DFHelp $topic }
}
Set-Alias -Name fh -Value Select-DFHelpTopic -Scope Global -Force
