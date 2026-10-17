#Requires -Version 7.2

# Alt+C (directory-jump): the folder list a picker shows, and the move to the
# picked folder. The sources are what the session's tools declare in their role
# blocks (navigation: directories, enter; file-search: directoryScan), so nothing
# here names a tool. Design: docs/superpowers/specs/2026-10-17-directory-jump-design.md.

function Get-DFDirectoryJumpCandidate {
    <#
    .SYNOPSIS
        Streams the folders Alt+C offers: ranked folders first, then a breadth-first scan of the current folder.
    .DESCRIPTION
        First the navigation winner's ranked folders (its "directories"
        command), shown as full paths with $HOME as ~. Then the folders under
        the current folder, one depth at a time up to -Depth, shown relative to
        it: through the file-search tool's "directoryScan" command when one is
        declared, else Get-ChildItem (hidden folders skipped). A folder already
        listed is not listed again (full path, case-insensitive). Items are
        written as they are found, so a picker can show them before the scan
        ends. Outside the file system only the ranked folders are listed.
    .PARAMETER Depth
        How deep to scan. Default: the DirectoryJumpDepth setting, else 6.
    .PARAMETER StopWhen
        Checked between folders, and every 100 ms while a scan command is
        silent; once it returns $true the list ends and a running scan process
        is stopped (the picker has closed).
    .OUTPUTS
        pscustomobject: Shown (the text to show), Path (the folder's full path).
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 64)][int]$Depth = (Get-DFConfig -Key DirectoryJumpDepth -Default 6), [scriptblock]$StopWhen = { $false })
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in Get-DFRankedDirectory -StopWhen $StopWhen) {
        if (& $StopWhen) { return }
        if ($seen.Add($path)) { [pscustomobject]@{ Shown = (Format-DFHomePath $path); Path = $path } }
    }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    # A pipeline, not foreach: foreach would collect the whole scan before the first folder.
    Get-DFScannedDirectory -Root $location.ProviderPath -Depth $Depth -StopWhen $StopWhen | ForEach-Object {
        if ($seen.Add($_.Path)) { $_ }
    }
}

function Invoke-DFStoppableCommand {
    <#
    .SYNOPSIS
        Runs an argv and writes its output lines as they come; a program is stopped once -StopWhen returns $true.
    .DESCRIPTION
        A program (an Application) runs as a process whose output is read line
        by line, checking -StopWhen between lines and every 100 ms while it is
        silent, and is killed when told to stop. Anything else (a function, as
        in tests) is called in the pipeline. Errors write a verbose message and
        end the output.
    .PARAMETER Argv
        The command and its arguments.
    .PARAMETER WorkingDirectory
        Where the program runs.
    .PARAMETER StopWhen
        The stop check.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Argv, [string]$WorkingDirectory, [scriptblock]$StopWhen = { $false })
    $application = Get-Command -Name $Argv[0] -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    # Splatted from a variable: an inline @(...) reaches a function as one argument.
    $rest = @($Argv | Select-Object -Skip 1)
    if (-not $application) {
        try { & $Argv[0] @rest 2>$null } catch { Write-Verbose "DotForge: Alt+C: '$($Argv[0])' failed: $($_.Exception.Message)" }
        return
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($application.Source)
    foreach ($argument in $rest) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try { $process = [System.Diagnostics.Process]::Start($startInfo) } catch { Write-Verbose "DotForge: Alt+C: couldn't start '$($Argv[0])': $($_.Exception.Message)"; return }
    try {
        $null = $process.StandardError.ReadToEndAsync()
        $next = $process.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($next.Wait(100)) {
                $line = $next.Result
                if ($null -eq $line) { break }
                $line
                $next = $process.StandardOutput.ReadLineAsync()
            }
            if (& $StopWhen) { break }
        }
    } finally {
        if (-not $process.HasExited) { try { $process.Kill($true) } catch { Write-Verbose "DotForge: Alt+C: couldn't stop '$($Argv[0])'" } }
        $process.Dispose()
    }
}

function Get-DFRankedDirectory {
    <#
    .SYNOPSIS
        The navigation winner's ranked folders (its declared "directories" command), as full paths; nothing on failure.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock]$StopWhen = { $false })
    $argv = @(Get-DFRoleDeclaration -Role navigation -Field directories)
    if (-not $argv.Count) { return }
    Invoke-DFStoppableCommand -Argv $argv -StopWhen $StopWhen | ForEach-Object {
        $line = ([string]$_).Trim()
        # Canonical, so a root stays a root (C:\, not the drive-relative C:).
        if ($line -and [System.IO.Path]::IsPathRooted($line)) { ConvertTo-DFPath $line }
    }
}

function Get-DFScannedDirectory {
    <#
    .SYNOPSIS
        The folders under -Root, one depth at a time (all of depth 1, then 2, ...), as Shown/Path items.
    .PARAMETER Root
        The folder to scan (a file-system path).
    .PARAMETER Depth
        The deepest level to list.
    .PARAMETER StopWhen
        The stop check (see Get-DFDirectoryJumpCandidate).
    .OUTPUTS
        pscustomobject: Shown (relative to Root), Path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Depth, [scriptblock]$StopWhen = { $false })
    $scan = @(Get-DFRoleDeclaration -Role file-search -Field directoryScan)
    if ($scan.Count) {
        foreach ($level in 1..$Depth) {
            if (& $StopWhen) { return }
            $argv = @($scan | ForEach-Object { ([string]$_).Replace('{depth}', [string]$level) })
            Invoke-DFStoppableCommand -Argv $argv -WorkingDirectory $Root -StopWhen $StopWhen | ForEach-Object {
                $relative = ([string]$_).Trim().TrimEnd('\', '/')
                if ($relative) { [pscustomobject]@{ Shown = $relative; Path = (ConvertTo-DFPath (Join-Path $Root $relative)) } }
            }
        }
        return
    }
    $frontier = @(Get-Item -LiteralPath $Root)
    foreach ($level in 1..$Depth) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($parent in $frontier) {
            if (& $StopWhen) { return }
            foreach ($child in @(Get-ChildItem -LiteralPath $parent.FullName -Directory -ErrorAction Ignore)) {
                if ($child.Name.StartsWith('.') -or $child.Attributes.HasFlag([System.IO.FileAttributes]::Hidden)) { continue }
                $next.Add($child)
                [pscustomobject]@{ Shown = [System.IO.Path]::GetRelativePath($Root, $child.FullName); Path = $child.FullName }
            }
        }
        if (-not $next.Count) { return }
        $frontier = $next
    }
}

function Format-DFHomePath {
    <#
    .SYNOPSIS
        A full path with a leading $HOME shown as ~.
    .PARAMETER Path
        The full path.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $homePath = $HOME.TrimEnd('\', '/')
    if ($Path -ieq $homePath) { return '~' }
    if ($Path.StartsWith($homePath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($homePath.Length)
    }
    $Path
}

function Enter-DFDirectory {
    <#
    .SYNOPSIS
        Moves the shell to a folder: through the navigation winner's "enter" command, else Set-Location -LiteralPath.
    .DESCRIPTION
        The folder is passed as one argument value, never as command text. With
        zoxide that is its cd, so the folder also counts toward its ranking. A
        folder that no longer exists gets one line saying so.
    .PARAMETER Path
        The folder's full path.
    .OUTPUTS
        System.Boolean. Whether the shell moved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-DFKeyMessage "DotForge: $Path no longer exists"
        return $false
    }
    $enter = Get-DFRoleDeclaration -Role navigation -Field enter
    try {
        if ($enter) { & $enter $Path | Out-Null } else { Set-Location -LiteralPath $Path }
        $true
    } catch {
        Write-DFKeyMessage "DotForge: couldn't change to ${Path}: $($_.Exception.Message)"
        $false
    }
}
