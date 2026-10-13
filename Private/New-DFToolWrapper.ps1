#Requires -Version 7.2

function Expand-DFToolToken {
    <#
    .SYNOPSIS
        Expands a tool record's path template: {settings.<name>} from the tool's settings, then ${XDG_*}, then canonicalizes it.
    .DESCRIPTION
        Returns $null (with a verbose message naming the tool and setting) when
        the template names a setting the tool doesn't have, so the caller can
        drop what depends on it instead of using a wrong path. The result goes
        through ConvertTo-DFPath, so a leading ~ expands to $HOME.
    .PARAMETER Tool
        A normalized tool record.
    .PARAMETER Text
        The template, e.g. '{settings.configPath}' or '${XDG_CONFIG_HOME}/lsd/config.yaml'.
    .OUTPUTS
        System.String, or $null when a referenced setting is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Text)
    $settings = $Tool.settings
    foreach ($match in [regex]::Matches($Text, '\{settings\.(\w+)\}')) {
        $setting = $match.Groups[1].Value
        if (-not $settings -or -not [string]$settings.PSObject.Properties[$setting]?.Value) {
            Write-Verbose "DotForge: $($Tool.name) has no setting '$setting' for '$Text'"
            return $null
        }
    }
    $filled = [regex]::Replace($Text, '\{settings\.(\w+)\}', { param($match) [string]$settings.PSObject.Properties[$match.Groups[1].Value].Value })
    ConvertTo-DFPath (Expand-DFXdgPath $filled)
}

function Format-DFWrapperHelp {
    <#
    .SYNOPSIS
        Returns the comment-based help block for a generated executable wrapper.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Name
        The wrapper's command name.
    .PARAMETER Description
        Extra description from a companion that builds the wrapper itself.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][string]$Name, [string]$Description)
    $exe = $Tool.executable
    $declared = @(foreach ($group in @($Tool.wrapper.args)) {
        $list = $group.args -join ' '
        if ($group.ifFile) { "$list (when $($group.ifFile) exists)" } else { $list }
    }) -join '; '
    $themeLine = if ($declared.Contains('{theme}')) { "`n        {theme} is the session's $($Tool.name) theme; Set-DFToolTheme switches it." } else { '' }
    $extra = if ($Description) { "`n        $Description" } else { '' }
    @"
    <#
    .SYNOPSIS
        Runs $exe with the arguments DotForge adds.
    .DESCRIPTION
        Wraps $exe and passes, before your own arguments: $declared.$themeLine$extra
        Piped input is passed through. Defined by DotForge from the wrapper block in $($Tool.name).json.
    .EXAMPLE
        $Name --help

        Runs $exe --help with DotForge's arguments.
    .OUTPUTS
        System.String. The output of $exe.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>

"@
}

function New-DFToolWrapper {
    <#
    .SYNOPSIS
        Defines a global function, named after a tool's executable, that runs it with the tool's declared wrapper arguments.
    .DESCRIPTION
        Builds the arguments on every call from wrapper.args: plain strings are
        always passed, an { ifFile, args } group only while its file exists
        ({file} is that path; ifFile may use {settings.<name>} and ${XDG_*}),
        and {theme} is the session theme's value (Get-DFSessionThemeValue), so
        Set-DFToolTheme takes effect at once. Your own arguments follow. Piped
        input is passed through (without that branch, a function with no
        process block swallows the pipeline and the tool waits on the
        console). The executable is called by its file name (glow.exe), so the
        wrapper never calls itself.
    .PARAMETER Tool
        A normalized tool record with a wrapper block.
    .PARAMETER Invoke
        Runs a non-piped call instead of the plain one, for a companion whose
        wrapper does more (fastfetch). Called as
        & $Invoke <executable> <declared args> <user args> <$MyInvocation>.
    .PARAMETER Description
        Extra text for the generated help's description.
    .OUTPUTS
        None. Defines function:global:<executable name>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [scriptblock]$Invoke,
        [string]$Description
    )
    # The generated function is a closure over these $_df* variables.
    $_dfExe = $Tool.executable
    $_dfToolName = $Tool.name
    $_dfInvoke = $Invoke
    $_dfThemeOf = ${function:Get-DFSessionThemeValue}
    $_dfGroups = @(foreach ($group in @($Tool.wrapper.args)) {
        $file = if ($group.ifFile) { Expand-DFToolToken -Tool $Tool -Text $group.ifFile }
        if ($group.ifFile -and -not $file) { continue }   # its file can't be named: never pass the group
        [pscustomobject]@{
            IfFile = $file
            Args   = [string[]]@(foreach ($arg in $group.args) { if ($file) { $arg.Replace('{file}', $file) } else { $arg } })
        }
    })
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_dfExe)
    $body = (Format-DFWrapperHelp -Tool $Tool -Name $name -Description $Description) + @'
    $declared = @(foreach ($group in $_dfGroups) {
        if ($group.IfFile -and -not (Test-Path -LiteralPath $group.IfFile -PathType Leaf)) { continue }
        foreach ($arg in $group.Args) { $arg.Replace('{theme}', [string](& $_dfThemeOf $_dfToolName)) }
    })
    if ($MyInvocation.ExpectingInput) { $input | & $_dfExe @declared @args; return }
    if ($_dfInvoke) { & $_dfInvoke $_dfExe $declared $args $MyInvocation; return }
    & $_dfExe @declared @args
'@
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body).GetNewClosure())
}
