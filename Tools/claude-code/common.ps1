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
        every update, so its stable sibling current\ is used when it has bash.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $execPath = Invoke-DFGitExecPath
    if (-not $execPath) { return $null }
    $git = Split-Path (Split-Path (Split-Path $execPath))
    $current = Join-Path (Split-Path $git) 'current' 'bin' 'bash.exe'
    if (Test-Path -LiteralPath $current -PathType Leaf) { return ConvertTo-DFPath $current }
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
        Reads Claude Code's settings.json as an ordered table: empty when there is none, $null when it isn't valid JSON (a note says so).
    .OUTPUTS
        System.Collections.IDictionary, or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFClaudeSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [ordered]@{} }
    try {
        $settings = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($null -eq $settings) { return [ordered]@{} }
        if ($settings -isnot [System.Collections.IDictionary]) { throw 'it holds no JSON object' }
        $settings
    } catch {
        Add-DFToolNote -Tool 'claude-code' -Note "$path isn't valid JSON, so DotForge left it alone ($($_.Exception.Message))"
        $null
    }
}

function script:Save-DFClaudeSettings {
    <#
    .SYNOPSIS
        Writes Claude Code's settings.json (two-space JSON, as Claude Code writes it).
    .PARAMETER Settings
        The table to write.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    Write-DFFileAtomic -Path (Get-DFClaudeSettingsPath) -Value ($Settings | ConvertTo-Json -Depth 20)
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
    .EXAMPLE
        Set-DFClaudeTheme -Name custom:catppuccin:catppuccin-mocha

        Installs the catppuccin theme plugin if needed and selects Catppuccin Mocha.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $builtin = 'dark', 'light', 'dark-daltonized', 'light-daltonized', 'dark-ansi', 'light-ansi'
    $plugin = if ($Name -match '^custom:([\w.-]+):[\w.-]+$') { $Matches[1] }
    if (-not $plugin -and $Name -notin $builtin) {
        Add-DFToolNote -Tool 'claude-code' -Note "Claude Code has no theme for '$Name'; its theme is left as it is"
        return
    }
    $settings = Read-DFClaudeSettings
    if ($null -eq $settings) { return }
    if ($settings['theme'] -ceq $Name) { return }
    if ($plugin) {
        $why = Install-DFClaudeThemePlugin -Plugin $plugin
        if ($why) { Add-DFToolNote -Tool 'claude-code' -Note "Claude Code's theme isn't set to $Name yet: $why"; return }
    }
    $settings['theme'] = $Name
    Save-DFClaudeSettings -Settings $settings
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
        if ('claude-themes' -notin $known) { $null = & $run 'plugin', 'marketplace', 'add', 'matcra587/claude-themes', '--scope', 'user' }
        $id = "$Plugin@claude-themes"
        $installed = @((& $run 'plugin', 'list', '--json') | ConvertFrom-Json) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $installed) { $null = & $run 'plugin', 'install', $id, '--scope', 'user' }
        elseif (-not $installed.enabled) { $null = & $run 'plugin', 'enable', $id, '--scope', 'user' }
    } catch {
        return $_.Exception.Message
    }
}
