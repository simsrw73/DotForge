#Requires -Version 7.0

function Invoke-DFHelp {
    <#
    .SYNOPSIS
        Displays colorized full help for a command, piped through the configured pager.
    .PARAMETER Name
        The name of the command, function, or alias to look up.
    .DESCRIPTION
        Fetches full help via Get-Help, optionally applies ANSI yellow highlighting
        to section headings (when the terminal supports VT sequences and NO_COLOR is
        not set), then sends the result through Invoke-DFWithPager for scrollable
        output.
    .EXAMPLE
        Invoke-DFHelp Get-ChildItem
        Shows full colorized help for Get-ChildItem in the configured pager.
    .EXAMPLE
        hm git
        Shows help for the git command using the hm alias.
    .OUTPUTS
        None
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
Set-Alias -Name hm -Value Invoke-DFHelp

function Select-DFCommand {
    <#
    .SYNOPSIS
        Fuzzy-searches all available commands and returns the selected command name.
    .PARAMETER Module
        Optional module name to restrict the command list.
    .DESCRIPTION
        Lists all commands (or those from a specific module) in fzf with a preview
        pane showing Get-Help output. Returns the selected command name so it can
        be used in further expressions or passed to Invoke-DFHelp.
    .EXAMPLE
        Select-DFCommand
        Opens fzf over all available commands; returns the selected command name.
    .EXAMPLE
        fcmd -Module DotForge
        Restricts the command list to DotForge functions using the fcmd alias.
    .OUTPUTS
        System.String — the name of the selected command.
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
Set-Alias -Name fcmd -Value Select-DFCommand

function Select-DFVerb {
    <#
    .SYNOPSIS
        Fuzzy-searches approved PowerShell verbs and returns the selected verb.
    .DESCRIPTION
        Presents all approved PowerShell verbs with their group (Lifecycle, Data,
        etc.) in fzf for quick lookup when naming new functions. Returns the verb
        string so it can be used directly in a function name.
    .EXAMPLE
        Select-DFVerb
        Opens fzf over approved verbs; outputs the selected verb name.
    .EXAMPLE
        fverb
        Same as above using the fverb alias.
    .OUTPUTS
        System.String — the selected PowerShell verb.
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List { Get-Verb | ForEach-Object { '{0,-20} {1}' -f $_.Verb, $_.Group } } `
        -Header 'Select verb  [Enter to output]' `
        -Parse { ($_ -split '\s+')[0] }
}
Set-Alias -Name fverb -Value Select-DFVerb

function Select-DFModule {
    <#
    .SYNOPSIS
        Fuzzy-searches all available modules and returns the selected module name.
    .DESCRIPTION
        Lists all modules available via Get-Module -ListAvailable in fzf, displaying
        name, version, and description. Returns the selected module name so it can
        be passed to Import-Module or inspected further.
    .EXAMPLE
        Select-DFModule
        Opens fzf over all available modules; outputs the selected module name.
    .EXAMPLE
        fmod
        Same as above using the fmod alias.
    .OUTPUTS
        System.String — the name of the selected module.
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List { Get-Module -ListAvailable |
            ForEach-Object { '{0,-40} {1,-10} {2}' -f $_.Name, $_.Version, $_.Description } } `
        -Header 'Select module  [Enter to output name]' `
        -Parse { ($_ -split '\s+')[0] }
}
Set-Alias -Name fmod -Value Select-DFModule

function Select-DFHelpTopic {
    <#
    .SYNOPSIS
        Fuzzy-searches all available PS help topics and opens the selected topic in Invoke-DFHelp.
    .PARAMETER Category
        Optional. Filters topics by Get-Help category (Cmdlet, Function, HelpFile, Module, etc.).
        No ValidateSet — accepts any string so future PS categories work without a code change.
    .PARAMETER Force
        Bypass the topic list cache and regenerate from Get-Help *.
    .DESCRIPTION
        Builds (and caches) the full list of Get-Help topics, presents them in fzf
        with a live preview pane, and opens the selected topic through Invoke-DFHelp.
        Requires $Env:XDG_CACHE_HOME to be set for the topic list cache to persist
        between sessions.
    .EXAMPLE
        Select-DFHelpTopic
        Opens fzf over all help topics; selecting one displays it in the pager.
    .EXAMPLE
        fh -Category HelpFile
        Filters to conceptual about_* help files before opening fzf.
    .EXAMPLE
        fh -Force
        Rebuilds the topic cache from Get-Help * before showing fzf.
    .OUTPUTS
        None
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
Set-Alias -Name fh -Value Select-DFHelpTopic

function Show-DFCliHelp {
    <#
    .SYNOPSIS
        Displays colorized help for an external CLI tool, auto-detecting the help flag.
    .DESCRIPTION
        Runs an external command with a help flag and colorizes the output: bold-yellow
        section headers and a faint tint on option flags. When -Flag is omitted the help
        flag is auto-detected (and cached) via Resolve-DFCliHelpFlag. Colorization is
        suppressed when $Env:NO_COLOR is set or the terminal lacks VT support. With -Paged
        the result is sent through Invoke-DFWithPager.
    .PARAMETER Name
        The external command to show help for (e.g. git, eza, docker).
    .PARAMETER Flag
        Explicit help flag to use. Skips auto-detection and caching.
    .PARAMETER Paged
        Send the colorized output through the configured pager.
    .PARAMETER Force
        Re-detect the help flag, ignoring and overwriting any cached value.
    .EXAMPLE
        Show-DFCliHelp eza
        Detects eza's help flag, colorizes the help, prints it to the terminal.
    .EXAMPLE
        clh git -Flag --tree
        Uses the clh alias with an explicit flag instead of auto-detection.
    .EXAMPLE
        clhp docker
        Shows colorized docker help through the pager.
    .OUTPUTS
        System.String — the colorized help text (unless -Paged, which writes to the pager).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Flag,

        [switch]$Paged,

        [switch]$Force
    )

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Warning "Show-DFCliHelp: '$Name' was not found on PATH."
        return
    }

    if ($PSBoundParameters.ContainsKey('Flag')) {
        $useFlag = $Flag
    } else {
        $useFlag = Resolve-DFCliHelpFlag -Name $Name -Force:$Force
    }

    if ($null -eq $useFlag) {
        Write-Warning "Show-DFCliHelp: could not determine a help flag for '$Name'."
        return
    }

    $raw = (Invoke-DFCommandCapture -Name $Name -Arguments @($useFlag)).Text
    $color = (-not $Env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
    $out = Format-DFCliHelpText -Text $raw -Color $color

    if ($Paged) { $out | Invoke-DFWithPager } else { $out }
}
Set-Alias -Name clh -Value Show-DFCliHelp

function Show-DFCliHelpPaged {
    <#
    .SYNOPSIS
        Paged variant of Show-DFCliHelp — colorized CLI help through the pager.
    .DESCRIPTION
        Thin wrapper that calls Show-DFCliHelp with -Paged. Exists as a function (not an
        alias) because a PowerShell alias cannot inject the -Paged argument.
    .PARAMETER Name
        The external command to show help for.
    .PARAMETER Flag
        Explicit help flag to use. Skips auto-detection.
    .PARAMETER Force
        Re-detect the help flag, ignoring any cached value.
    .EXAMPLE
        Show-DFCliHelpPaged eza
        Shows colorized eza help through the configured pager.
    .EXAMPLE
        clhp git
        Same as above using the clhp alias.
    .OUTPUTS
        None. Output is written to the pager.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Flag,

        [switch]$Force
    )
    $params = @{ Name = $Name; Paged = $true }
    if ($PSBoundParameters.ContainsKey('Flag')) { $params.Flag = $Flag }
    if ($Force) { $params.Force = $true }
    Show-DFCliHelp @params
}
Set-Alias -Name clhp -Value Show-DFCliHelpPaged
