function Get-DFCompletionMode {
    <#
    .SYNOPSIS
        Returns the completion mode from $DFConfig.CompletionMode: 'Native' (default) or 'Inshellisense'.
    .DESCRIPTION
        Case-insensitive. An unset or empty value is 'Native'; any other value
        warns and falls back to 'Native'.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    param()
    $mode = [string](Get-DFConfig CompletionMode)
    if (-not $mode -or $mode -ieq 'Native') { return 'Native' }
    if ($mode -ieq 'Inshellisense') { return 'Inshellisense' }
    Write-Warning "DotForge: CompletionMode '$mode' is invalid; using Native."
    'Native'
}

function Enable-DFCarapaceInshellisenseBridge {
    <#
    .SYNOPSIS
        Adds 'inshellisense' to $Env:CARAPACE_BRIDGES in Native mode when the is (or inshellisense) command exists.
    .DESCRIPTION
        Called by Tools/carapace.ps1 before carapace's init runs. Keeps any
        bridges the user already listed, drops duplicates (case-insensitive),
        and appends 'inshellisense' once. Does nothing in Inshellisense mode,
        where inshellisense runs directly instead of as a carapace bridge.
    .OUTPUTS
        System.Boolean. $true when the bridge is enabled.
    #>
    [CmdletBinding()]
    param()
    if ((Get-DFCompletionMode) -ne 'Native') { return $false }
    $executable = Get-Command is -ErrorAction Ignore
    if (-not $executable) { $executable = Get-Command inshellisense -ErrorAction Ignore }
    if (-not $executable) { return $false }
    $bridges = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($bridge in @($Env:CARAPACE_BRIDGES -split ',')) {
        $name = $bridge.Trim()
        if ($name -and $seen.Add($name)) { $bridges.Add($name) }
    }
    if ($seen.Add('inshellisense')) { $bridges.Add('inshellisense') }
    $Env:CARAPACE_BRIDGES = $bridges -join ','
    $true
}

function Enable-DFFzfAnsiOption {
    <#
    .SYNOPSIS
        Appends --ansi to $Env:FZF_DEFAULT_OPTS unless it is already there.
    .DESCRIPTION
        Carapace styles completion ListItemText with ANSI colour escapes whenever it
        is attached to a console (invisible when stdout is redirected, e.g. in tests).
        PSFzf's Tab handler pipes those strings to fzf, so fzf must be told to render
        ANSI or it prints the raw escapes. --ansi is a documented fzf option; setting
        it via FZF_DEFAULT_OPTS (fzf merges this env var into every invocation) keeps
        us off PSFzf's internal command construction. The returned CompletionText is
        never styled, so the inserted text stays clean.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    foreach ($tok in ($existing -split '\s+')) {
        if ($tok -ceq '--ansi') { return }
    }
    $Env:FZF_DEFAULT_OPTS = if ($existing) { "$existing --ansi" } else { '--ansi' }
}

function Initialize-DFCompletionStack {
    <#
    .SYNOPSIS
        Binds Tab once, after every tool in a Register-DFTool call has registered.
    .DESCRIPTION
        Runs at the end of Register-DFTool, so it sees the final set of
        registered tools and PSReadLine's final edit mode. (Changing EditMode
        resets Tab, which is why psreadline.ps1 applies EditMode during
        registration and users are told not to change it afterwards.)

        Inshellisense mode: starts inshellisense via Start-DFInshellisense and
        leaves Tab alone. Falls back to Native, with a warning, when the is
        command or the starter (defined by Tools/inshellisense.ps1) is missing.

        Native mode, in priority order:
          PSFzf registered    Tab = PSFzf's fuzzy completion (Invoke-FzfTabCompletion);
                              with carapace also registered, fzf gets --ansi so
                              carapace's colored items render.
          carapace only       Tab = PSReadLine MenuComplete.
          neither             Tab keeps PSReadLine's default for the edit mode.
        Carapace's completers themselves are registered by Tools/carapace.ps1;
        both Tab handlers reach them through TabExpansion2.
    .PARAMETER RegisteredTools
        Names of the tools Register-DFTool actually registered this call
        (installed and not skipped). Compared case-insensitively.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([string[]]$RegisteredTools)
    $tools = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tool in @($RegisteredTools)) { if ($tool) { $null = $tools.Add($tool) } }
    if ((Get-DFCompletionMode) -eq 'Inshellisense') {
        $executable = Get-Command is -ErrorAction Ignore
        # Start-DFInshellisense invokes the is executable directly.
        if ($executable -and (Get-Command Start-DFInshellisense -ErrorAction Ignore)) {
            Start-DFInshellisense
            return
        }
        Write-Warning 'DotForge: Inshellisense completion requested but its executable or starter was not found; using Native.'
    }
    if ($tools.Contains('psfzf')) {
        if ($tools.Contains('carapace')) { Enable-DFFzfAnsiOption }
        Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
    }
    elseif ($tools.Contains('carapace')) { Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete }
}
