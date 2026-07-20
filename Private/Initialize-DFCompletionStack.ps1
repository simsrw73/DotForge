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
    if ($tools.Contains('psfzf')) { Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion } }
    elseif ($tools.Contains('carapace')) { Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete }
}