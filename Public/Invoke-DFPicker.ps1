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
        Ignored when -Expect is used (the caller branches on the returned .Key).
    .PARAMETER Expect
        fzf --expect keys (e.g. 'alt-r','alt-i'). When set, fzf reports which key
        the user pressed and the picker switches to "multi-key" mode: instead of
        returning/acting on the parsed value, it returns a single object
        [pscustomobject]@{ Key = <pressed key>; Selected = @(<parsed items>) }.
        The pressed key is '' when the user accepted with Enter. -Action is not
        invoked in this mode.
    .PARAMETER Bind
        fzf --bind specs (e.g. 'alt-i:execute(winget install --id {2})'). Each
        entry is passed as its own --bind. Use for act-in-place bindings that run
        a command while fzf stays open.
    .PARAMETER FzfArgs
        Extra fzf arguments passed through verbatim (appended last). Escape hatch
        for fzf flags this function does not model directly.
    .DESCRIPTION
        Invokes fzf with the provided list, optional preview, header, and flags.
        The selected item is optionally transformed by -Parse, then passed to
        -Action or returned on the output stream. Uses the private Invoke-DFFzf
        wrapper so callers can mock fzf in tests without spawning a real process.
    .EXAMPLE
        Invoke-DFPicker -List { git branch } -Header 'Select branch' -Action { param($b) git checkout $b }
        Fuzzy-selects a git branch and checks it out.
    .EXAMPLE
        $file = Invoke-DFPicker -List { Get-ChildItem -Name } -Preview 'cat {}'
        Fuzzy-selects a file from the current directory; returns the selected name.
    .EXAMPLE
        $r = Invoke-DFPicker -List { winget-lines } -Expect 'alt-r' -Parse { ($_ -split "`t")[1] }
        if ($r.Key -eq 'alt-r') { Install $r.Selected } else { "install $($r.Selected)" }
        Uses --expect so Enter and Alt-R select the same item but drive different actions.
    .OUTPUTS
        System.String — selected (and optionally parsed) item when -Action is omitted.
        None — when -Action is provided (side-effect only).
        System.Management.Automation.PSCustomObject — { Key; Selected } when -Expect is used.
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
        [scriptblock]$Action,
        [string[]]$Expect,
        [string[]]$Bind,
        [string[]]$FzfArgs
    )

    $pickerArgs = [System.Collections.Generic.List[string]]@('--preview-window', $PreviewWindow)
    if ($Preview)   { $pickerArgs.AddRange([string[]]@('--preview',   $Preview)) }
    if ($Header)    { $pickerArgs.AddRange([string[]]@('--header',    $Header)) }
    if ($Ansi)      { $pickerArgs.Add('--ansi') }
    if ($Multi)     { $pickerArgs.Add('--multi') }
    if ($Delimiter) { $pickerArgs.AddRange([string[]]@('--delimiter', $Delimiter)) }
    if ($WithNth)   { $pickerArgs.AddRange([string[]]@('--with-nth',  $WithNth)) }
    if ($Expect)    { $pickerArgs.AddRange([string[]]@('--expect', ($Expect -join ','))) }
    foreach ($b in $Bind) { $pickerArgs.AddRange([string[]]@('--bind', $b)) }
    if ($FzfArgs)   { $pickerArgs.AddRange([string[]]$FzfArgs) }

    $items = @(& $List)
    $selected = Invoke-DFFzf -InputItems $items -FzfArgs $pickerArgs
    if (-not $selected) { return }

    if ($Expect) {
        # fzf prints the pressed key on the first line (empty string for Enter),
        # then the selection(s). Return both so the caller can branch on the key.
        $lines  = @($selected)
        $key    = $lines[0]
        $picked = @($lines | Select-Object -Skip 1 | ForEach-Object {
            if ($Parse) { $_ | ForEach-Object $Parse } else { $_ }
        })
        return [pscustomobject]@{ Key = $key; Selected = $picked }
    }

    foreach ($item in @($selected)) {
        $value = if ($Parse) { $item | ForEach-Object $Parse } else { $item }
        if ($Action) { & $Action $value } else { $value }
    }
}
