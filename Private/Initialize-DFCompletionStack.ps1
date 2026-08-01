function Get-DFCompletionMode {
    [CmdletBinding()]
    param()
    $mode = if (Test-Path Variable:Global:DFConfig) { [string]$Global:DFConfig.CompletionMode }
    if (-not $mode -or $mode -ieq 'Native') { return 'Native' }
    if ($mode -ieq 'Inshellisense') { return 'Inshellisense' }
    Write-Warning "DotForge: CompletionMode '$mode' is invalid; using Native."
    'Native'
}

function Enable-DFCarapaceInshellisenseBridge {
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
    # Carapace styles completion ListItemText with ANSI colour escapes whenever it
    # is attached to a console (invisible when stdout is redirected, e.g. in tests).
    # PSFzf's Tab handler pipes those strings to fzf, so fzf must be told to render
    # ANSI or it prints the raw escapes. --ansi is a documented fzf option; setting
    # it via FZF_DEFAULT_OPTS (fzf merges this env var into every invocation) keeps
    # us off PSFzf's internal command construction. The returned CompletionText is
    # never styled, so the inserted text stays clean.
    [CmdletBinding()]
    param()
    $existing = [string]$Env:FZF_DEFAULT_OPTS
    foreach ($tok in ($existing -split '\s+')) {
        if ($tok -ceq '--ansi') { return }
    }
    $Env:FZF_DEFAULT_OPTS = if ($existing) { "$existing --ansi" } else { '--ansi' }
}

function Initialize-DFCompletionStack {
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