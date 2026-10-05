#Requires -Version 7.0

function Write-DFRoleNotice {
    <#
    .SYNOPSIS
        Warns when DotForge had to guess the winner of an exclusive role.
    .DESCRIPTION
        For each exclusive role whose winner was chosen by priority (two or more
        candidates and no usable $DFConfig.Defaults entry), warns once naming the
        winner and the line that picks another tool. "Once" is per candidate set,
        recorded in <XDG state>/dotforge/role-state.json, so installing another
        candidate warns again. An unreadable state file counts as empty; a failed
        write is ignored. Never throws.
    .PARAMETER RoleWinners
        Get-DFRoleWinners result.
    .PARAMETER RoleDb
        Role definitions (Get-DFRoleDb).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$RoleWinners,
        [hashtable]$RoleDb = (Get-DFRoleDb)
    )
    $guessed = @($RoleWinners.Values | Where-Object {
        $_.Reason -eq 'priority' -and $RoleDb.ContainsKey($_.Role) -and $RoleDb[$_.Role].exclusive
    })
    if (-not $guessed) { return }

    $stateFile = Join-Path (Get-DFXdgPath State) 'dotforge' 'role-state.json'
    $state = @{}
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $state = @{} }
        if ($state -isnot [hashtable]) { $state = @{} }
    }

    $changed = $false
    foreach ($w in $guessed | Sort-Object Role) {
        $key = $w.Candidates -join ','
        if ($state[$w.Role] -eq $key) { continue }
        $other = $w.Candidates | Where-Object { $_ -ne $w.Winner } | Select-Object -First 1
        Write-Warning ("DotForge: $($w.Candidates -join ', ') can each fill the $($w.Role) role; using $($w.Winner). " +
            "Choose with `$DFConfig.Defaults = @{ '$($w.Role)' = '$other' }")
        $state[$w.Role] = $key
        $changed = $true
    }
    if ($changed) {
        try { Write-DFFileAtomic -Path $stateFile -Value ($state | ConvertTo-Json) } catch { Write-Verbose "DotForge: could not save role state: $($_.Exception.Message)" }
    }
}
