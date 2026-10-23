#Requires -Version 7.2

function New-DFToolPickerFunction {
    <#
    .SYNOPSIS
        Builds and installs a tool's declarative fzf pickers as global
        functions (and aliases, where declared).
    .DESCRIPTION
        Reads $Tool.picker (one object, or a list of them, as a normalized
        record has) and defines, for each, a global function that calls
        Invoke-DFPicker with it.
        When picker.list_accepts_path is true, the function takes a -Path
        parameter (default '.') appended to the list command. Quoted arguments
        in the list command are supported. Skips a null or "custom" picker,
        and a picker that lacks a function/list pair.
    .PARAMETER Tool
        The normalized tool record declaring the pickers.
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tool
    )

    if ($Tool.picker -is [string]) { return }
    foreach ($picker in @($Tool.picker)) {
        if ($picker -is [PSCustomObject] -and $picker.function -and $picker.list) { Set-DFPickerFunction -Picker $picker }
    }
}

function Set-DFPickerFunction {
    <#
    .SYNOPSIS
        Defines one declarative picker's global function, and its alias if declared.
    .PARAMETER Picker
        One declarative picker object (function and list set).
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Picker)

    # A fresh scope per picker, so each function's closure captures its own values.
    $picker = $Picker

    # Everything except the list source is the same for both shapes, so the
    # Invoke-DFPicker call is built once. GetNewClosure captures these locals.
    $action = if ($picker.action -and $picker.action -ne 'output') {
        [scriptblock]::Create("param(`$v) " + $picker.action.Replace('{}', '$v'))
    }
    $parse = if ($picker.parse) { [scriptblock]::Create($picker.parse) }
    # A preview that draws icons may declare a plain one for while icons are off.
    $plain = $picker.PSObject.Properties['preview_plain']?.Value
    $preview = if ($plain -and -not (Test-DFIconsOn)) { $plain } else { $picker.preview }
    $show = {
        param([scriptblock]$List)
        Invoke-DFPicker -List $List -Preview $preview -PreviewWindow $picker.preview_window `
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
