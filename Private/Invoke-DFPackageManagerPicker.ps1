#Requires -Version 7.2

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

# Each package-manager companion (Tools/winget.ps1, scoop.ps1, choco.ps1)
# registers a spec here; its three pickers then call Invoke-DFPackageManagerAction.
if (-not (Get-Variable -Name DFPackageManagerSpecs -Scope Script -ErrorAction Ignore)) { $script:DFPackageManagerSpecs = @{} }

function Invoke-DFPackageManagerAction {
    <#
    .SYNOPSIS
        Runs one package-manager picker (search and install, uninstall, or update) from that manager's spec.
    .DESCRIPTION
        The control flow every package-manager picker shares: check the
        manager's dependency, build the list, show the picker, then act on the
        pressed key. Everything that differs between managers (which commands
        list and act, how a line is formatted, the command strings, the wording)
        comes from the spec the companion registered in $script:DFPackageManagerSpecs:

            Name              'winget'
            Require           { $true if usable; warns itself otherwise }
            SearchPrompt      prompt when -Query is empty
            Preview           fzf preview command, {2} is the id
            Search            { param($Query) lines 'display<TAB>id' }
            Installed         { param($Source) lines for installed packages }
            Outdated          { lines for packages with an update }
            InstallCommand    install command, {0} is the id
            UninstallCommand  uninstall command, {0} is the id
            InPlace           { param($command) the command for fzf's execute() keys }
            Install, Uninstall, Update   { param($Id) do it }
            UpdateAll         { update everything }
            UpdateWord        'upgrade' or 'update' (header text)
            UpdatingWord      'Upgrading' or 'Updating' (progress text)
            AllMessage        progress text for update-all
    .PARAMETER Manager
        The spec name, e.g. 'winget'.
    .PARAMETER Action
        Install (search, then return or run the install command), Uninstall, or Update.
    .PARAMETER Query
        Search terms for Install; prompted for when empty.
    .PARAMETER Source
        Passed to the spec's Installed list (winget filters by it).
    .OUTPUTS
        System.String: the install or uninstall command, when the key asks for
        the command instead of running it. Otherwise none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall', 'Update')][string]$Action,
        [string]$Query = '',
        [string]$Source = ''
    )
    $spec = $script:DFPackageManagerSpecs[$Manager]
    if (-not (& $spec.Require)) { return }
    $name = $spec.Name
    $inPlace = { param($template) & $spec.InPlace ($template -f '{2}') }

    switch ($Action) {
        'Install' {
            if (-not $Query) { $Query = Read-Host $spec.SearchPrompt }
            # Resolved here, then closed over as plain data, so the picker's scope
            # doesn't need $Query.
            $items = @(& $spec.Search $Query)
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name search  [Enter=command | Alt-R=install | Alt-I=install in place]" `
                -ExpectKey 'alt-r' -Bind "alt-i:execute($(& $inPlace $spec.InstallCommand))"
            if (-not $sel) { return }
            $id = @($sel.Selected)[0]
            if (-not $id) { return }   # only the in-place Alt-I bind ran; nothing chosen on exit
            if ($sel.Key -eq 'alt-r') {
                Write-Host "⚙  Installing $id…" -ForegroundColor Cyan
                & $spec.Install $id
            } else {
                $spec.InstallCommand -f $id   # Enter: the command, to review or run
            }
        }
        'Uninstall' {
            $items = @(& $spec.Installed $Source)
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name uninstall  [Enter=uninstall | Alt-X=uninstall in place | Alt-C=command]" `
                -ExpectKey 'alt-c' -Bind "alt-x:execute($(& $inPlace $spec.UninstallCommand))"
            if (-not $sel) { return }
            $id = @($sel.Selected)[0]
            if (-not $id) { return }
            if ($sel.Key -eq 'alt-c') {
                $spec.UninstallCommand -f $id
            } else {
                Write-Host "⚙  Uninstalling $id…" -ForegroundColor DarkYellow
                & $spec.Uninstall $id
            }
        }
        'Update' {
            $items = @(& $spec.Outdated)
            $word = $spec.UpdateWord
            $sel = Invoke-DFPackageManagerPicker -ListItems { $items }.GetNewClosure() -PreviewCommand $spec.Preview `
                -Header "$name $word  [Tab=mark | Enter=$word marked | Alt-A=$word all]" -ExpectKey 'alt-a' -Multi
            if (-not $sel) { return }
            if ($sel.Key -eq 'alt-a') {
                Write-Host "⚙  $($spec.AllMessage)" -ForegroundColor Green
                & $spec.UpdateAll
                return
            }
            foreach ($id in $sel.Selected) {
                if ($id) {
                    Write-Host "⚙  $($spec.UpdatingWord) $id…" -ForegroundColor Green
                    & $spec.Update $id
                }
            }
        }
    }
}

function Register-DFPrefillChord {
    <#
    .SYNOPSIS
        Binds a PSReadLine chord that replaces the command line with the install command a search picker returns.
    .DESCRIPTION
        Type a search term, press the chord, pick a package: the term is
        replaced by the picker's install command, ready to edit or run. Uses
        the current line as the query and does nothing on an empty line. A
        no-op when PSReadLine isn't loaded.
    .PARAMETER Chord
        The PSReadLine chord, e.g. 'Ctrl+g,w'.
    .PARAMETER Picker
        The search picker to run with -Query, e.g. 'Select-WingetPackage'.
    .PARAMETER Description
        Shown by Get-PSReadLineKeyHandler.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Chord,
        [Parameter(Mandatory)][string]$Picker,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore)) { return }
    Set-PSReadLineKeyHandler -Chord $Chord -Description $Description -ScriptBlock {
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $cmd = & $Picker -Query $line
        if ($cmd -is [string] -and $cmd.Trim()) {
            [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)
        }
    }.GetNewClosure()
}
