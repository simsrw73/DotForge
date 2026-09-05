#Requires -Version 7.0

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs one tool's declarative fzf picker as a global
        function (and alias, if declared).
    .DESCRIPTION
        Reads $Tool.picker (list/preview/header/action/parse/etc., all plain
        strings per the JSON schema) and assembles an Invoke-DFPicker call as
        a global function via [scriptblock]::Create and .GetNewClosure(). When
        picker.list_accepts_path is true, the generated function instead
        takes a -Path parameter and splits the list command on whitespace to
        append it (existing behavior, including its known limitation with
        quoted arguments -- unchanged by this extraction; see TODO.md). No-ops
        when $Tool has no picker, or the picker lacks a function/list pair.
        Extracted verbatim from Register-DFTool's per-tool loop -- no
        behavior change from the prior inline version.
    .PARAMETER Tool
        The tool record declaring the picker.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $picker = $Tool.PSObject.Properties['picker']?.Value
    if (-not $picker -or $picker -isnot [PSCustomObject]) { return }

    $pAlias    = $picker.PSObject.Properties['alias']?.Value
    $pFunction = $picker.PSObject.Properties['function']?.Value
    $pList     = $picker.PSObject.Properties['list']?.Value
    $pPreview  = $picker.PSObject.Properties['preview']?.Value ?? ''
    $pWindow   = $picker.PSObject.Properties['preview_window']?.Value ?? 'right:60%'
    $pAnsi     = [bool]($picker.PSObject.Properties['ansi']?.Value)
    $pHeader   = $picker.PSObject.Properties['header']?.Value ?? ''
    $pAction   = $picker.PSObject.Properties['action']?.Value
    $pParse    = $picker.PSObject.Properties['parse']?.Value
    $pAccPath  = [bool]($picker.PSObject.Properties['list_accepts_path']?.Value)

    if (-not ($pFunction -and $pList)) { return }

    $capturedList    = $pList
    $capturedPreview = $pPreview
    $capturedWindow  = $pWindow
    $capturedAnsi    = $pAnsi
    $capturedHeader  = $pHeader
    $capturedAction  = if ($pAction -and $pAction -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $pAction.Replace('{}', '$v'))
    } else { $null }
    $capturedParse   = if ($pParse) {
        [scriptblock]::Create($pParse)
    } else { $null }

    $fn = if ($pAccPath) {
        $capturedParts = @($capturedList -split '\s+')
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            Invoke-DFPicker `
                -List          { & $capturedParts[0] @($capturedParts[1..($capturedParts.Count - 1)]) $Path } `
                -Preview       $capturedPreview `
                -PreviewWindow $capturedWindow `
                -Ansi:$capturedAnsi `
                -Header        $capturedHeader `
                -Parse         $capturedParse `
                -Action        $capturedAction
        }.GetNewClosure()
    } else {
        {
            [CmdletBinding()]
            param()
            Invoke-DFPicker `
                -List          ([scriptblock]::Create($capturedList)) `
                -Preview       $capturedPreview `
                -PreviewWindow $capturedWindow `
                -Ansi:$capturedAnsi `
                -Header        $capturedHeader `
                -Parse         $capturedParse `
                -Action        $capturedAction
        }.GetNewClosure()
    }

    Set-Item -Path "function:global:$pFunction" -Value $fn
    if ($pAlias) {
        Set-Alias -Name $pAlias -Value $pFunction -Scope Global -Force
    }
}
