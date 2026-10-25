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
        Adopt.
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
    $items = @((Find-DFToolConflict -Tool $Tool -Ownership $Ownership -Written ($global:DFEnvState?.Written ?? @{})).Conflicts)
    if (-not $items) {
        Write-Host "$($Tool.name) has no existing data in the way; DotForge links or uses the XDG locations when it loads it."
        $Result.Action = 'Nothing'
        return $Result
    }
    $what = @($items | ForEach-Object { "$($_.Target) -> $($_.Existing)" }) -join ', '
    if (-not $Cmdlet.ShouldProcess($Tool.name, "Set the XDG copies aside and link: $what")) { return $Result }
    $renamed = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($items | Where-Object Action -eq 'Conflict')) {
        try {
            $aside = Rename-DFOldCopy -Path $item.Target
            $renamed.Add([pscustomobject]@{ From = $item.Target; To = $aside })
        } catch {
            $Result.Problems = [string[]](@($Result.Problems) + "couldn't set $($item.Target) aside: $($_.Exception.Message)")
            foreach ($done in $renamed) { Rename-Item -LiteralPath $done.To -NewName (Split-Path $done.From -Leaf) -ErrorAction Ignore }
            Write-Warning "DotForge: nothing changed for $($Tool.name): $($Result.Problems -join '; ')"
            return $Result
        }
    }
    $Result.Aside = [string[]]@($renamed.To)
    $links = @(foreach ($item in $items) {
        $made = (New-DFToolLink -Path $item.Target -Target $item.Existing).Made
        if ($made) { $Result.Linked = [string[]](@($Result.Linked) + $item.Target) }
        [pscustomobject]@{ key = $item.Key; path = $item.Target; target = $item.Existing; made = $made }
    })
    $Ownership[$Tool.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'linked'; links = $links }
    Save-DFToolOwnership -Ownership $Ownership -Name $Tool.name
    if ($renamed.Count) { Write-Host "Set aside (delete when you're satisfied): $($renamed.To -join ', ')" }
    Write-Host "Linked $what. Load it with: Register-DFTool -Name $($Tool.name)"
    $Result
}

function Invoke-DFConflictGuide {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict with no tool name: goes through every tool waiting on the user, offering each one's advised action.
    .DESCRIPTION
        Enter adopts (Get-DFConflictAdvice); A adopts, S skips. Where it can't
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
        if ("$answer".Trim() -notmatch '^([Aa]|$)') { continue }
        $result = Resolve-DFToolConflict -Name $status.Name -Adopt -Confirm:$false
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
    Read-Host "  $Name - [A]dopt or [S]kip (Enter: $Default)"
}
