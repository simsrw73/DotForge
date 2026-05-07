#Requires -Version 7.0

function Invoke-DFPicker {
    <#
    .SYNOPSIS
        Generalized fzf picker. Handles list -> fzf -> parse -> action skeleton.
    .PARAMETER List
        Scriptblock that produces the items to display in fzf.
    .PARAMETER Header
        Header text shown at the top of the fzf window.
    .PARAMETER Preview
        fzf --preview string. Use {} as placeholder for the selected item.
    .PARAMETER PreviewWindow
        fzf --preview-window value. Default: 'right:60%'.
    .PARAMETER Ansi
        Pass --ansi to fzf (for ANSI-colored input).
    .PARAMETER Multi
        Pass --multi to fzf; Action is called once per selected item.
    .PARAMETER Delimiter
        fzf --delimiter value.
    .PARAMETER WithNth
        fzf --with-nth value (which fields to display).
    .PARAMETER Parse
        Scriptblock to transform the raw fzf output line. $_ is the raw line.
        If omitted, the raw line is used as-is.
    .PARAMETER Action
        Scriptblock invoked with the parsed value as param($v).
        If omitted, the parsed value is written to the output stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$List,
        [string]$Header        = '',
        [string]$Preview       = '',
        [string]$PreviewWindow = 'right:60%',
        [switch]$Ansi,
        [switch]$Multi,
        [string]$Delimiter     = '',
        [string]$WithNth       = '',
        [scriptblock]$Parse,
        [scriptblock]$Action
    )

    $fzfArgs = [System.Collections.Generic.List[string]]@('--preview-window', $PreviewWindow)
    if ($Preview)   { $fzfArgs.AddRange([string[]]@('--preview',   $Preview)) }
    if ($Header)    { $fzfArgs.AddRange([string[]]@('--header',    $Header)) }
    if ($Ansi)      { $fzfArgs.Add('--ansi') }
    if ($Multi)     { $fzfArgs.Add('--multi') }
    if ($Delimiter) { $fzfArgs.AddRange([string[]]@('--delimiter', $Delimiter)) }
    if ($WithNth)   { $fzfArgs.AddRange([string[]]@('--with-nth',  $WithNth)) }

    $items = @(& $List)
    $selected = Invoke-DFFzf -InputItems $items -FzfArgs $fzfArgs
    if (-not $selected) { return }

    foreach ($item in @($selected)) {
        $value = if ($Parse) { $item | ForEach-Object $Parse } else { $item }
        if ($Action) { & $Action $value } else { $value }
    }
}
