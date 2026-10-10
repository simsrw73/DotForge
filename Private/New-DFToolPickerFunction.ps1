#Requires -Version 7.2

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs one tool's declarative fzf picker as a global
        function (and alias, if declared).
    .DESCRIPTION
        Reads $Tool.picker (a normalized record from ConvertTo-DFToolRecord)
        and defines a global function that calls Invoke-DFPicker with it.
        When picker.list_accepts_path is true, the function takes a -Path
        parameter (default '.') appended to the list command, which is split on
        whitespace (so quoted arguments in the list command are not supported;
        see TODO.md). No-ops when $Tool has no object picker, or the picker
        lacks a function/list pair.
    .PARAMETER Tool
        The normalized tool record declaring the picker.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    $picker = $Tool.picker
    if ($picker -isnot [PSCustomObject] -or -not ($picker.function -and $picker.list)) { return }

    # Everything except the list source is the same for both shapes, so the
    # Invoke-DFPicker call is built once. GetNewClosure captures these locals.
    $action = if ($picker.action -and $picker.action -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $picker.action.Replace('{}', '$v'))
    }
    $parse = if ($picker.parse) { [scriptblock]::Create($picker.parse) }
    $show = {
        param([scriptblock]$List)
        Invoke-DFPicker -List $List -Preview $picker.preview -PreviewWindow $picker.preview_window `
            -Ansi:$picker.ansi -Header $picker.header -Parse $parse -Action $action
    }.GetNewClosure()

    $fn = if ($picker.list_accepts_path) {
        $listParts = @($picker.list -split '\s+')
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            & $show { & $listParts[0] @($listParts[1..($listParts.Count - 1)]) $Path }.GetNewClosure()
        }.GetNewClosure()
    } else {
        $list = [scriptblock]::Create($picker.list)
        {
            [CmdletBinding()]
            param()
            & $show $list
        }.GetNewClosure()
    }

    Set-Item -Path "function:global:$($picker.function)" -Value $fn
    if ($picker.alias) {
        Set-Alias -Name $picker.alias -Value $picker.function -Scope Global -Force
    }
}
