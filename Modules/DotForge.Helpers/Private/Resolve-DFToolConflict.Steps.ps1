#Requires -Version 7.2

# The steps of Resolve-DFToolConflict. See
# docs/superpowers/specs/2026-10-11-config-ownership-design.md.

function New-DFConflictResult {
    <#
    .SYNOPSIS
        An empty Resolve-DFToolConflict result.
    .PARAMETER Tool
        The tool.
    .PARAMETER Action
        Move, Adopt or Done.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][string]$Action)
    [pscustomobject]@{
        PSTypeName = 'DotForge.ConflictResult'
        Tool       = $Tool
        Action     = $Action
        Moved      = [string[]]@()
        Pending    = [string[]]@()
        Problems   = [string[]]@()
    }
}

function Complete-DFConflictPending {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict -Done: forgets a move's unfinished removals, keeping ownership.
    .PARAMETER Name
        The tool.
    .PARAMETER Ownership
        Read-DFToolOwnership result (updated and saved).
    .PARAMETER Result
        The result object to return.
    .PARAMETER Cmdlet
        The caller's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    param([string]$Name, [hashtable]$Ownership, $Result, $Cmdlet)
    $entry = $Ownership[$Name]
    if (-not ($entry -and $entry.PSObject.Properties['pending'])) {
        Write-Host "$Name has no unfinished removals."
        return $Result
    }
    $Result.Pending = [string[]]@($entry.pending | ForEach-Object OldPath)
    if ($Cmdlet.ShouldProcess($Name, "Stop retrying the removal of $($Result.Pending -join ', ')")) {
        $entry.PSObject.Properties.Remove('pending')
        Save-DFToolOwnership -Ownership $Ownership
        $Result.Pending = [string[]]@()
    }
    $Result
}

function Invoke-DFConflictMove {
    <#
    .SYNOPSIS
        Resolve-DFToolConflict -Move.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Ownership
        Read-DFToolOwnership result.
    .PARAMETER Result
        The result object to fill and return.
    .PARAMETER Cmdlet
        The caller's $PSCmdlet, for ShouldProcess.
    .OUTPUTS
        DotForge.ConflictResult.
    #>
    param($Tool, [hashtable]$Ownership, $Result, $Cmdlet)
    $conflicts = @((Find-DFToolConflict -Tool $Tool -Ownership $Ownership).Conflicts)
    if (-not $conflicts) {
        Write-Host "Nothing of $($Tool.name)'s is in its old locations; DotForge takes it over on its next load."
        return $Result
    }
    $Result.Problems = [string[]]@(Get-DFMoveProblem -Tool $Tool -Conflicts $conflicts)
    if ($Result.Problems) {
        Write-Warning "DotForge: $($Tool.name)'s config can't be moved safely yet:"
        foreach ($problem in $Result.Problems) { Write-Warning "  $problem" }
        return $Result
    }
    $plan = ($conflicts | ForEach-Object { "$(@($_.OldPaths)[0]) -> $($_.Target)" }) -join '; '
    if (-not $Cmdlet.ShouldProcess($Tool.name, "Move $plan, then move the old copies out of the way")) { return $Result }

    $pending = Copy-DFConflictLocation -Conflicts $conflicts
    $Result.Moved = [string[]]@($pending.Target)
    # Recorded before anything is removed, so a crash leaves a record of what moved.
    $Ownership[$Tool.name] = [pscustomobject]@{ since = [DateTime]::UtcNow.ToString('o'); how = 'move'; pending = @($pending) }
    Save-DFToolOwnership -Ownership $Ownership
    $left = @(foreach ($item in $pending) {
        try { Remove-DFItemToBin -Path $item.OldPath } catch { $item }
    })
    $entry = $Ownership[$Tool.name]
    if ($left) { $entry.pending = $left } else { $entry.PSObject.Properties.Remove('pending') }
    Save-DFToolOwnership -Ownership $Ownership
    $Result.Pending = [string[]]@($left | ForEach-Object OldPath)
    if ($left) { Write-Warning "DotForge: $($Result.Pending -join ', ') is in use; DotForge removes it on a later load." }
    Write-Host "DotForge now owns $($Tool.name)'s config. Load it with: Register-DFTool -Name $($Tool.name)"
    $Result
}

function Copy-DFConflictLocation {
    <#
    .SYNOPSIS
        Copies each conflict's old location to its target, verified; on any failure removes every target it made and throws.
    .PARAMETER Conflicts
        Find-DFToolConflict's Conflicts (each with one old path, checked by Get-DFMoveProblem).
    .OUTPUTS
        One pending item per conflict: OldPath, Target, Files (Copy-DFVerified's manifest).
    #>
    param([Parameter(Mandatory)][object[]]$Conflicts)
    $done = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($conflict in $Conflicts) {
            $old = @($conflict.OldPaths)[0]
            $files = Copy-DFVerified -Source $old -Target $conflict.Target
            $done.Add([pscustomobject]@{ OldPath = $old; Target = $conflict.Target; Files = @($files) })
        }
    } catch {
        foreach ($item in $done) { Remove-Item -LiteralPath $item.Target -Recurse -Force -ErrorAction Ignore }
        throw
    }
    $done.ToArray()
}

function Copy-DFVerified {
    <#
    .SYNOPSIS
        Copies a file or folder to Target through a staging copy, checking every file's size and SHA-256.
    .PARAMETER Source
        The old location.
    .PARAMETER Target
        The XDG location (empty, by Get-DFMoveProblem).
    .OUTPUTS
        The manifest: Path (relative; empty for a single file), Length and
        Hash per file. Throws, with staging removed, when a copy differs.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    $staging = "$Target.dotforge-staging"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
    New-DFDirectory (Split-Path $Target) | Out-Null
    $isFile = Test-Path -LiteralPath $Source -PathType Leaf
    $activity = "Checking the copy of $Source"
    try {
        Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force -ErrorAction Stop
        $files = @(if ($isFile) { Get-Item -LiteralPath $Source -Force } else { Get-ChildItem -LiteralPath $Source -File -Recurse -Force })
        $count = 0
        $manifest = foreach ($file in $files) {
            $count++
            Write-Progress -Activity $activity -Status $file.Name -PercentComplete ($count * 100 / $files.Count)
            $relative = if ($isFile) { '' } else { [IO.Path]::GetRelativePath($Source, $file.FullName) }
            $copy = if ($isFile) { $staging } else { Join-Path $staging $relative }
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $copyInfo = Get-Item -LiteralPath $copy -Force -ErrorAction Ignore
            if (-not $copyInfo -or $copyInfo.Length -ne $file.Length -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $hash) {
                throw "DotForge: the copy of $($file.FullName) didn't verify; nothing was moved."
            }
            [pscustomobject]@{ Path = $relative; Length = $file.Length; Hash = $hash }
        }
        Write-Progress -Activity $activity -Completed
        # The target holds no files (checked), but may be an empty folder.
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop }
        Move-Item -LiteralPath $staging -Destination $Target -ErrorAction Stop
        @($manifest)
    } catch {
        Write-Progress -Activity $activity -Completed
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
        throw
    }
}

function Get-DFPathSpelling {
    <#
    .SYNOPSIS
        The ways a config file might write a path: both separators, ~, and the environment-variable forms.
    .PARAMETER Path
        A canonical path.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$Path)
    $forms = [System.Collections.Generic.List[string]]::new()
    $forms.Add($Path)
    $roots = @(
        @{ Value = Get-DFNativeRoot -Name HOME; Names = '~', '$HOME', '${HOME}', '%USERPROFILE%', '$env:USERPROFILE' }
        @{ Value = Get-DFNativeRoot -Name APPDATA; Names = '%APPDATA%', '$env:APPDATA', '${APPDATA}' }
        @{ Value = Get-DFNativeRoot -Name LOCALAPPDATA; Names = '%LOCALAPPDATA%', '$env:LOCALAPPDATA', '${LOCALAPPDATA}' }
    )
    foreach ($root in $roots) {
        if (-not $root.Value) { continue }
        $base = ConvertTo-DFPath $root.Value
        if (-not $Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rest = $Path.Substring($base.Length)
        foreach ($rootName in $root.Names) { $forms.Add($rootName + $rest) }
    }
    @($forms | ForEach-Object { $_; $_.Replace('\', '/') } | Select-Object -Unique)
}

function Find-DFOldPathReference {
    <#
    .SYNOPSIS
        Text files under Root that name any of the spellings, as "<file>:<line>".
    .DESCRIPTION
        Text means under 1 MB with no NUL byte in the first 8 KB. Matching
        ignores case.
    .PARAMETER Root
        A file or folder.
    .PARAMETER Spelling
        Get-DFPathSpelling result.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Spelling)
    $files = if (Test-Path -LiteralPath $Root -PathType Leaf) { Get-Item -LiteralPath $Root -Force }
             else { Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction Ignore }
    foreach ($file in $files) {
        if ($file.Length -ge 1MB) { continue }
        $head = [byte[]]::new([Math]::Min(8KB, $file.Length))
        $stream = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try { $null = $stream.Read($head, 0, $head.Length) } finally { $stream.Dispose() }
        if ($head -contains 0) { continue }
        foreach ($hit in @(Select-String -LiteralPath $file.FullName -SimpleMatch -Pattern $Spelling -ErrorAction Ignore)) {
            "$($file.FullName):$($hit.LineNumber)"
        }
    }
}

function Get-DFMoveProblem {
    <#
    .SYNOPSIS
        Why moving a tool's old config to its XDG location isn't safe yet; nothing when it is.
    .DESCRIPTION
        Each line says what to fix. Checked: the tool allows the move; one old
        copy per path; the target is empty; no text file under the old
        location, and no user or session environment variable, names the old
        location; the tool isn't running.
    .PARAMETER Tool
        The tool record.
    .PARAMETER Conflicts
        Find-DFToolConflict's Conflicts.
    .OUTPUTS
        System.String[].
    #>
    param([Parameter(Mandatory)][pscustomobject]$Tool, [Parameter(Mandatory)][object[]]$Conflicts)
    $problems = foreach ($conflict in $Conflicts) {
        if (-not $conflict.Move) { "$($conflict.Key): DotForge doesn't move this one. $($conflict.Guide)"; continue }
        if (@($conflict.OldPaths).Count -gt 1) {
            "$($conflict.Key): there are copies in $(@($conflict.OldPaths) -join ' and '); keep one and delete the others, then run this again."
            continue
        }
        if (Test-DFPathHasContent -Path $conflict.Target) {
            "$($conflict.Key): $($conflict.Target) already has files; merge them yourself, or run Resolve-DFToolConflict $($Tool.name) -Adopt."
        }
        $old = @($conflict.OldPaths)[0]
        $spellings = Get-DFPathSpelling -Path $old
        foreach ($reference in @(Find-DFOldPathReference -Root $old -Spelling $spellings)) {
            "$reference names the old location; change it to $($conflict.Target), then run this again."
        }
        foreach ($scope in 'User', 'Process') {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            foreach ($key in $vars.Keys) {
                $value = "$($vars[$key])"
                if (@($spellings | Where-Object { $value.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
                    "the environment variable $key names $old; change it first."
                }
            }
        }
    }
    if ($Tool.type -ne 'module') {
        $exe = [IO.Path]::GetFileNameWithoutExtension($Tool.executable)
        if (Get-Process -Name $exe -ErrorAction Ignore) { "$exe is running; close $exe first." }
    }
    @($problems | Select-Object -Unique)
}
