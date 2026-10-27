#Requires -Version 7.2

# Helpers shared by Tools/claude-code.ps1 (the companion) and Tools/claude-code.setup.ps1. Defined at
# script scope, so they outlive the load: Set-DFToolTheme calls Set-DFClaudeTheme later. Every call to
# the real claude goes through Invoke-DFClaudeCli, and git through Invoke-DFGitExecPath (seams tests
# mock). See docs/superpowers/specs/2026-10-27-claude-code-design.md.

function script:Invoke-DFClaudeCli {
    <#
    .SYNOPSIS
        Runs claude with arguments and returns its exit code and output (the seam tests mock).
    .PARAMETER Arguments
        The arguments.
    .OUTPUTS
        PSCustomObject: ExitCode, Output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not (Get-Command claude -CommandType Application -ErrorAction Ignore)) {
        return [pscustomobject]@{ ExitCode = 127; Output = "Claude Code isn't installed" }
    }
    $output = & claude @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function script:Invoke-DFGitExecPath {
    <#
    .SYNOPSIS
        git --exec-path, or $null without git (a seam tests mock).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command git -CommandType Application -ErrorAction Ignore)) { return $null }
    $path = & git --exec-path 2>$null
    if ($LASTEXITCODE -eq 0 -and $path) { "$path".Trim() }
}

function script:Find-DFGitBash {
    <#
    .SYNOPSIS
        Git for Windows' bash.exe, for Claude Code's Bash and Monitor tools; $null without git.
    .DESCRIPTION
        git's exec path is <git>\<mingw64|ucrt64>\libexec\git-core, so bash is
        <git>\bin\bash.exe. A scoop install's versioned <git> folder changes on
        every update, so its stable sibling current\ is used, but only when it
        is a link to that same folder (what scoop makes): a plain folder named
        current is never trusted.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $execPath = Invoke-DFGitExecPath
    if (-not $execPath) { return $null }
    $git = Split-Path (Split-Path (Split-Path $execPath))
    $currentDir = Join-Path (Split-Path $git) 'current'
    $link = (Get-Item -LiteralPath $currentDir -Force -ErrorAction Ignore)?.LinkTarget
    $current = Join-Path $currentDir 'bin' 'bash.exe'
    if ($link -and (ConvertTo-DFPath $link) -eq (ConvertTo-DFPath $git) -and (Test-Path -LiteralPath $current -PathType Leaf)) {
        return ConvertTo-DFPath $current
    }
    $bash = Join-Path $git 'bin' 'bash.exe'
    if (Test-Path -LiteralPath $bash -PathType Leaf) { ConvertTo-DFPath $bash }
}

function script:Get-DFClaudeSettingsPath {
    <#
    .SYNOPSIS
        Claude Code's user settings file: $CLAUDE_CONFIG_DIR\settings.json, else $XDG_CONFIG_HOME\claude\settings.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = if ($Env:CLAUDE_CONFIG_DIR) { $Env:CLAUDE_CONFIG_DIR } else { Join-Path (Get-DFXdgPath Config) 'claude' }
    ConvertTo-DFPath (Join-Path $dir 'settings.json')
}

function script:Read-DFClaudeSettings {
    <#
    .SYNOPSIS
        Reads Claude Code's settings.json as a JSON object: empty when there is none, $null when it isn't plain JSON (a note says so).
    .DESCRIPTION
        Parsed strictly with System.Text.Json (no comments, no trailing commas,
        which a rewrite would drop), keeping key order and strings as written
        (PowerShell's JSON cmdlets turn date-like strings into dates and, on
        7.2, reorder keys).
    .OUTPUTS
        System.Text.Json.Nodes.JsonObject, or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFClaudeSettingsPath
    # The comma keeps PowerShell from unrolling the (enumerable) object into nothing.
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , [System.Text.Json.Nodes.JsonObject]::new() }
    try {
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($text)) { return , [System.Text.Json.Nodes.JsonObject]::new() }
        $settings = [System.Text.Json.Nodes.JsonNode]::Parse($text)
        if ($settings -isnot [System.Text.Json.Nodes.JsonObject]) { throw 'it holds no JSON object' }
        , $settings
    } catch {
        Add-DFToolNote -Tool 'claude-code' -Note "$path isn't valid JSON, so DotForge left it alone ($($_.Exception.Message))"
        $null
    }
}

function script:Save-DFClaudeSettings {
    <#
    .SYNOPSIS
        Writes Claude Code's settings.json (two-space JSON, as Claude Code writes it), through a link to its target.
    .PARAMETER Settings
        The JSON object to write.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.Nodes.JsonObject]$Settings)
    $path = Get-DFClaudeSettingsPath
    $link = (Get-Item -LiteralPath $path -Force -ErrorAction Ignore)
    if ($link -and $link.LinkTarget) { $path = $link.ResolveLinkTarget($true).FullName }
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    Write-DFFileAtomic -Path $path -Value $Settings.ToJsonString($options)
}

function script:Set-DFClaudeSetting {
    <#
    .SYNOPSIS
        Sets one string value in a settings JSON object.
    .PARAMETER Object
        The JSON object.
    .PARAMETER Key
        The key.
    .PARAMETER Value
        The string.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.Nodes.JsonObject]$Object, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Value)
    $Object[$Key] = [System.Text.Json.Nodes.JsonValue]::Create($Value)
}

function script:Set-DFClaudeTheme {
    <#
    .SYNOPSIS
        Sets Claude Code's theme: a claude-themes theme (custom:<plugin>:<theme>) after adding the marketplace and installing and enabling the plugin, or one of Claude's own.
    .DESCRIPTION
        Nothing runs when settings.json already has the theme. Otherwise, in
        order: the claude-themes marketplace is added if Claude Code doesn't
        know it, the theme's plugin is installed (or enabled), and only then
        settings.json's theme key is written; nothing else in the file
        changes. When a step fails (offline, Claude Code not installed yet),
        the theme is left as it is and Get-DFToolStatus claude-code says why.
        The theme block in Tools/claude-code.json maps DotForge's theme names
        to these ids; Set-DFToolTheme calls this.
    .PARAMETER Name
        custom:<plugin>:<theme> (a claude-themes theme), or one of Claude Code's own themes.
    .PARAMETER Background
        A shell load (the companion): after a failed step, try again at most once
        a day, so an offline machine doesn't pay for claude on every start.
    .EXAMPLE
        Set-DFClaudeTheme -Name custom:catppuccin:catppuccin-mocha

        Installs the catppuccin theme plugin if needed and selects Catppuccin Mocha.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Background)
    $builtin = 'dark', 'light', 'dark-daltonized', 'light-daltonized', 'dark-ansi', 'light-ansi'
    $plugin = if ($Name -match '^custom:([\w.-]+):[\w.-]+$') { $Matches[1] }
    if (-not $plugin -and $Name -notin $builtin) {
        Add-DFToolNote -Tool 'claude-code' -Note "Claude Code has no theme for '$Name'; its theme is left as it is"
        return
    }
    $settings = Read-DFClaudeSettings
    if ($null -eq $settings) { return }
    if ($settings.ContainsKey('theme') -and [string]$settings['theme'] -ceq $Name) { return }
    if ($plugin) {
        $retry = Join-Path (Get-DFXdgPath State) 'dotforge' 'claude-theme-failed.txt'
        if ($Background -and (Test-Path -LiteralPath $retry) -and (Get-Item -LiteralPath $retry).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) {
            Add-DFToolNote -Tool 'claude-code' -Note "Claude Code's theme isn't set to $Name yet: the last try failed; DotForge tries again tomorrow, or now with Set-DFToolTheme"
            return
        }
        $why = Install-DFClaudeThemePlugin -Plugin $plugin
        if ($why) {
            Write-DFFileAtomic -Path $retry -Value $why
            Add-DFToolNote -Tool 'claude-code' -Note "Claude Code's theme isn't set to $Name yet: $why"
            return
        }
        Remove-Item -LiteralPath $retry -ErrorAction Ignore
        # Read again: claude plugin just wrote extraKnownMarketplaces and enabledPlugins to this file.
        $settings = Read-DFClaudeSettings
        if ($null -eq $settings) { return }
    }
    Set-DFClaudeSetting -Object $settings -Key 'theme' -Value $Name
    Save-DFClaudeSettings -Settings $settings
    Remove-DFToolNote -Tool 'claude-code' -Like "Claude Code's theme isn't set*"
}

function script:Install-DFClaudeThemePlugin {
    <#
    .SYNOPSIS
        Makes a claude-themes plugin usable: marketplace added, plugin installed and enabled; returns why not, or nothing.
    .PARAMETER Plugin
        The plugin (theme family), e.g. catppuccin.
    .OUTPUTS
        System.String: the failure, or nothing on success.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Plugin)
    $run = { param([string[]]$Arguments)
        $result = Invoke-DFClaudeCli -Arguments $Arguments
        if ($result.ExitCode -ne 0) { throw "claude $($Arguments -join ' ') failed: $("$($result.Output)".Trim())" }
        $result.Output
    }
    try {
        $known = @((& $run 'plugin', 'marketplace', 'list', '--json') | ConvertFrom-Json) | ForEach-Object { $_.name }
        if ('claude-themes' -notin $known) {
            $null = & $run 'plugin', 'marketplace', 'add', 'matcra587/claude-themes', '--scope', 'user'
            Add-DFToolNote -Tool 'claude-code' -Note 'added the claude-themes plugin marketplace (github.com/matcra587/claude-themes) to Claude Code'
        }
        $id = "$Plugin@claude-themes"
        $installed = @((& $run 'plugin', 'list', '--json') | ConvertFrom-Json) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $installed) {
            $null = & $run 'plugin', 'install', $id, '--scope', 'user'
            Add-DFToolNote -Tool 'claude-code' -Note "installed the $id theme plugin (from github.com/matcra587/claude-themes) in Claude Code"
        }
        elseif (-not $installed.enabled) { $null = & $run 'plugin', 'enable', $id, '--scope', 'user' }
    } catch {
        return $_.Exception.Message
    }
}
