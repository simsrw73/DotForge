#Requires -Version 7.2

# The steps of Resolve-DFToolConflict. See
# docs/superpowers/specs/2026-10-25-link-existing-design.md.

function New-DFConflictResult {
    <#
    .SYNOPSIS
        An empty Resolve-DFToolConflict result.
    .PARAMETER Tool
        The tool.
    .PARAMETER Action
        Adopt or KeepXdg.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Action)
    [pscustomobject]@{
        PSTypeName = 'DotForge.ConflictResult'
        Tool       = $Tool
        Action     = $Action
        Linked     = [string[]]@()
        Aside      = [string[]]@()
        Problems   = [string[]]@()
    }
}

function Invoke-DFConflictSetAside {
    <#
    .SYNOPSIS
        Renames each path aside (Rename-DFOldCopy), all or none: if one fails, those already renamed are renamed back.
    .PARAMETER Paths
        The copies to set aside.
    .PARAMETER Result
        New-DFConflictResult; Aside gets the new paths, or Problems why nothing changed.
    .PARAMETER Tool
        The tool's name, for the warning.
    .OUTPUTS
        System.Boolean: whether every path was set aside.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$Tool
    )
    $renamed = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        try {
            $aside = Rename-DFOldCopy -Path $path
            $renamed.Add([pscustomobject]@{ From = $path; To = $aside })
        } catch {
            $Result.Problems = [string[]](@($Result.Problems) + "couldn't set $path aside: $($_.Exception.Message)")
            foreach ($done in $renamed) { Rename-Item -LiteralPath $done.To -NewName (Split-Path $done.From -Leaf) -ErrorAction Ignore }
            Write-Warning "DotForge: nothing changed for ${Tool}: $($Result.Problems -join '; ')"
            return $false
        }
    }
    $Result.Aside = [string[]]@($renamed.To)
    if ($renamed.Count) { Write-Host "Set aside (delete when you're satisfied): $($renamed.To -join ', ')" }
    $true
}

function Invoke-DFConflictAdopt {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict -Adopt: sets each XDG copy in the way aside, links every XDG location to the existing data, and records the links.
    .DESCRIPTION
        All renames happen first; if one fails, the ones already done are
        renamed back and nothing else changes. Then each location is linked
        (New-DFToolLink) and the tool recorded as owned, how 'linked'.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result; the tool's entry is added and saved.
    .PARAMETER Result
        New-DFConflictResult.
    .PARAMETER Cmdlet
        Resolve-DFToolConflict's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership,
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)]$Cmdlet
    )
    $items = @((Find-DFToolConflict -Tool $Tool -Ownership $Ownership -Written (${global:DFEnvState}?.Written ?? @{})).Conflicts)
    if (-not $items) {
        Write-Host "$($Tool.name) has no existing data in the way; DotForge links or uses the XDG locations when it loads it."
        $Result.Action = 'Nothing'
        return $Result
    }
    $what = @($items | ForEach-Object { "$($_.Target) -> $($_.Existing)" }) -join ', '
    if (-not $Cmdlet.ShouldProcess($Tool.name, "Set the XDG copies aside and link: $what")) { return $Result }
    $inWay = [string[]]@($items | Where-Object Action -eq 'Conflict' | ForEach-Object Target)
    if (-not (Invoke-DFConflictSetAside -Paths $inWay -Result $Result -Tool $Tool.name)) { return $Result }
    $links = @(foreach ($item in $items) {
        $made = (New-DFToolLink -Path $item.Target -Target $item.Existing).Made
        if ($made) { $Result.Linked = [string[]](@($Result.Linked) + $item.Target) }
        [pscustomobject]@{ key = $item.Key; path = $item.Target; target = $item.Existing; made = $made }
    })
    $Ownership[$Tool.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'linked'; links = $links }
    Save-DFToolOwnership -Ownership $Ownership -Name $Tool.name
    Write-Host "Linked $what. Load it with: Register-DFTool -Name $($Tool.name)"
    $Result
}

function Invoke-DFConflictKeepXdg {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict -KeepXdg: sets the existing copies aside wherever the XDG location holds content too, so the tool uses the XDG copy.
    .DESCRIPTION
        Every old location with content (OldPaths) of each conflict is
        renamed aside, all or none (Invoke-DFConflictSetAside). Nothing is
        linked or recorded: the next load finds the old locations empty and
        points the tool at the XDG folders, linking any other XDG location
        that is still empty, as usual. A conflict whose existing copy is where
        a variable set outside DotForge points is refused before anything
        changes: DotForge never overrides that variable, so the user removes it.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .PARAMETER Result
        New-DFConflictResult.
    .PARAMETER Cmdlet
        Resolve-DFToolConflict's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Ownership,
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)]$Cmdlet
    )
    $found = Find-DFToolConflict -Tool $Tool -Ownership $Ownership -Written (${global:DFEnvState}?.Written ?? @{})
    $items = @($found.Conflicts | Where-Object Action -eq 'Conflict')
    if (-not $items) {
        Write-Host "$($Tool.name) has no existing copy in the way of its XDG locations; nothing to do."
        $Result.Action = 'Nothing'
        return $Result
    }
    foreach ($item in $items) {
        $value = if ($item.Key -cnotmatch '^\$\{') { [Environment]::GetEnvironmentVariable($item.Key, 'Process') }
        if ($value -and (ConvertTo-DFPath $value) -eq $item.Existing) {
            $Result.Problems = [string[]](@($Result.Problems) + "your $($item.Key) points at $($item.Existing): remove that variable (from your profile or user environment), open a new shell, and run this again")
        }
    }
    if (@($Result.Problems)) {
        Write-Warning "DotForge: nothing changed for $($Tool.name): $($Result.Problems -join '; ')"
        return $Result
    }
    $old = [string[]]@($items | ForEach-Object OldPaths | Select-Object -Unique)
    if (-not $Cmdlet.ShouldProcess($Tool.name, "Set your existing copies aside, keeping the XDG copies: $($old -join ', ')")) { return $Result }
    if (-not (Invoke-DFConflictSetAside -Paths $old -Result $Result -Tool $Tool.name)) { return $Result }
    Write-Host "$($Tool.name) uses its XDG copies from now on. Load it with: Register-DFTool -Name $($Tool.name)"
    $Result
}

function Invoke-DFConflictGuide {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict with no tool name: goes through every tool waiting on the user, offering each one's advised action.
    .DESCRIPTION
        Enter adopts (Get-DFConflictAdvice); A adopts, K keeps the XDG copy, S skips. Where it can't
        ask (no interactive console), it only lists the tools and their advice.
    .OUTPUTS
        DotForge.ConflictResult per tool resolved.
    #>
    [CmdletBinding()]
    param()
    $waiting = @(Get-DFToolStatus -Conflict 3>$null)
    if (-not $waiting) { Write-Host 'No tools are waiting on your existing config.'; return }
    $ask = Test-DFConflictPrompt
    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($status in $waiting) {
        $advice = Get-DFConflictAdvice -Name $status.Name -Conflicts @($status.Conflicts)
        Write-Host "$($status.Name): your existing data at $(@($status.Conflicts.OldPaths) -join ', ') and the XDG location both hold content. $($advice.Text)"
        if (-not $ask) { continue }
        $answer = Read-DFConflictChoice -Name $status.Name -Default $advice.Action
        $choice = switch -Regex ("$answer".Trim()) { '^([Aa]|)$' { 'Adopt' } '^[Kk]$' { 'KeepXdg' } default { $null } }
        if (-not $choice) { continue }
        $how = @{ $choice = $true }
        $result = Resolve-DFToolConflict -Name $status.Name @how -Confirm:$false
        $result
        if ($result -and -not @($result.Problems)) { $resolved.Add($status.Name) }
    }
    if ($resolved.Count) { Write-Host "Load them with: Register-DFTool -Name $($resolved -join ', ')" }
}

function Test-DFConflictPrompt {
    <#
    .SYNOPSIS
        Whether Resolve-DFToolConflict can ask: an interactive console whose input isn't redirected.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected
}

function Read-DFConflictChoice {
    <#
    .SYNOPSIS
        Asks what to do with one tool; returns the typed answer ('' for Enter).
    .PARAMETER Name
        The tool.
    .PARAMETER Default
        What Enter does: Adopt.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Default)
    Read-Host "  $Name - [A]dopt, [K]eep XDG or [S]kip (Enter: $Default)"
}
