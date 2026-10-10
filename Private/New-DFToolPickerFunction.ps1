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
        parameter (default '.') appended to the list command. Quoted arguments
        in the list command are supported. No-ops when $Tool has no object
        picker, or the picker lacks a function/list pair.
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

    $list = if ($picker.list_accepts_path) {
        [scriptblock]::Create("$($picker.list) @args")
    }
    $fn = if ($picker.list_accepts_path) {
        {
            [CmdletBinding()]
            param([string]$Path = '.')
            # A local copy: the inner .GetNewClosure() captures only this scope's variables,
            # not the outer closure's (the old code's $listParts was $null there).
            $listToInvoke = $list
            & $show { & $listToInvoke $Path }.GetNewClosure()
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
