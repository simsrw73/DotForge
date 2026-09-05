#Requires -Version 7.0

function Invoke-DFPackageManagerPicker {
    <#
    .SYNOPSIS
        Shared fzf-picker wiring for the scoop/winget/choco package-manager
        sidecars: delimiter, first-field display, preview debounce prefix,
        preview window, tab-split parse, and the --expect/--bind pass-through.
    .DESCRIPTION
        Each package-manager sidecar (Tools/scoop.ps1, Tools/winget.ps1,
        Tools/choco.ps1) builds its own item list and its own post-selection
        action (install/uninstall/update via that package manager's own
        module or CLI) -- those stay in each sidecar, since they are
        genuinely different per tool. This helper only collapses the part
        that was byte-for-byte identical across all nine pickers: the
        Invoke-DFPicker wiring call itself.
    .PARAMETER ListItems
        Scriptblock producing the picker's display lines (tab-delimited:
        display text first, the parsed key second).
    .PARAMETER PreviewCommand
        The package manager's own preview command (e.g. 'scoop info {2}').
        The 'ping -n 2 127.0.0.1 >nul &' debounce prefix -- which stops fast
        scrolling from spawning a preview process per skipped item -- is
        added here once, instead of at each of the nine call sites.
    .PARAMETER Header
        Header text shown at the top of the fzf window.
    .PARAMETER ExpectKey
        fzf --expect key name (e.g. 'alt-r', 'alt-c', 'alt-a').
    .PARAMETER Bind
        fzf --bind spec for the in-place execute() key. Omit for update
        pickers, which have no in-place bind.
    .PARAMETER Multi
        Pass -Multi through to Invoke-DFPicker (update pickers only).
    .OUTPUTS
        [pscustomobject]@{ Key; Selected } -- see Invoke-DFPicker's -Expect
        behavior, which every package-manager picker relies on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ListItems,
        [Parameter(Mandatory)][string]$PreviewCommand,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$ExpectKey,
        [string]$Bind,
        [switch]$Multi
    )

    # Splatted conditionally rather than always passing -Bind $Bind: explicitly
    # binding a $null scalar to Invoke-DFPicker's [string[]]$Bind parameter gets
    # coerced into a one-element array containing $null (not a true empty/null
    # collection), so its `foreach ($b in $Bind)` would iterate once and emit a
    # bare, argument-less --bind. Omitting the key entirely avoids that.
    $pickerArgs = @{
        List          = $ListItems
        Delimiter     = "`t"
        WithNth       = '1'
        Multi         = $Multi
        Preview       = "ping -n 2 127.0.0.1 >nul & $PreviewCommand"
        PreviewWindow = 'right:60%'
        Header        = $Header
        Parse         = { ($_ -split "`t")[1] }
        Expect        = $ExpectKey
    }
    if ($Bind) { $pickerArgs['Bind'] = $Bind }

    Invoke-DFPicker @pickerArgs
}
