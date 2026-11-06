#Requires -Version 7.2

# Desktop Path entries: the Windows user PATH (HKCU\Environment, value Path) that programs started
# outside pwsh see. Stateless primitives for reading and writing it safely, resolving a segment to
# its real folder, and finding other copies of a command. See
# docs/superpowers/specs/2026-11-03-desktop-path-design.md.

function Get-DFUserPathValue {
    <#
    .SYNOPSIS
        The user Path as stored (%VARIABLES% unexpanded); an empty string when there is none.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $stored = Get-DFDesktopEnvValue -Name Path
    if ($null -eq $stored) { return '' }
    "$stored"
}

function Set-DFUserPathValue {
    <#
    .SYNOPSIS
        Writes the user Path, without a broadcast; keeps the value's registry kind, and a new value is ExpandString.
    .PARAMETER Value
        The whole Path value.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # A failed write throws (a terminating error): callers must never go on as if it were written.
    $key = $null
    try {
        $key = Open-DFDesktopEnvKey -Create
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') {
            $existing = $key.GetValueKind('Path')
            if ($existing -eq [Microsoft.Win32.RegistryValueKind]::String) { $kind = $existing }
        }
        $key.SetValue('Path', $Value, $kind)
    } catch { throw } finally { if ($key) { $key.Dispose() } }
}

function Get-DFSystemPathValue {
    <#
    .SYNOPSIS
        The machine Path as stored (%VARIABLES% unexpanded); read only, and a seam tests mock.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Test-DFIsWindows)) { return '' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    if (-not $key) { return '' }
    try { "$($key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))" }
    finally { $key.Dispose() }
}

function ConvertTo-DFDesktopPathText {
    <#
    .SYNOPSIS
        The canonical folder a Path segment names as written, without touching the file system; $null when it names none.
    .DESCRIPTION
        %VARIABLES% expand as desktop apps get them. An empty segment, a
        relative one (after expansion) or one that can't be parsed gives $null,
        silently. Links aren't followed: Resolve-DFDesktopPathFolder does that.
    .PARAMETER Segment
        One Path segment, as stored.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $null }
    try {
        $expanded = (Expand-DFDesktopEnvValue -Value $Segment.Trim()).Trim('"')
        if (-not [IO.Path]::IsPathFullyQualified($expanded)) { return $null }
        ConvertTo-DFPath $expanded
    } catch { $null }
}

function Resolve-DFDesktopPathFolder {
    <#
    .SYNOPSIS
        The canonical folder a Path segment names as desktop apps see it, junctions followed; $null when it names none.
    .DESCRIPTION
        %VARIABLES% expand as desktop apps get them. An empty segment, a
        relative one (after expansion) or one that can't be parsed gives $null,
        silently. A folder that exists and is itself a link resolves to its
        target (a link in a parent folder isn't followed).
    .PARAMETER Segment
        One Path segment, as stored.
    .OUTPUTS
        System.String, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Segment)
    $folder = ConvertTo-DFDesktopPathText -Segment $Segment
    if (-not $folder) { return $null }
    try {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $target = [IO.Directory]::ResolveLinkTarget($folder, $true)
            if ($target) { $folder = ConvertTo-DFPath $target.FullName }
        }
        $folder
    } catch { $null }
}

function Find-DFDesktopPathSegment {
    <#
    .SYNOPSIS
        The index of the first Path segment that names a folder, however it is written; -1 when none does.
    .DESCRIPTION
        First the folder as written: the first segment whose text names it
        (%VARIABLES% expanded, compared canonically and case-insensitively),
        with no file-system call, so an unreachable segment never stalls a
        load. That is also the segment DotForge wrote, so removal takes it
        rather than an earlier one that only links to the same folder. Only
        when no segment names it as written are links followed on both sides.
    .PARAMETER Value
        A Path value, as stored.
    .PARAMETER Folder
        The folder to look for.
    .OUTPUTS
        System.Int32.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Folder)
    $segments = $Value -split ';'
    $written = ConvertTo-DFDesktopPathText -Segment $Folder
    if (-not $written) { return -1 }
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $text = ConvertTo-DFDesktopPathText -Segment $segments[$index]
        if ($text -and [string]::Equals($text, $written, [StringComparison]::OrdinalIgnoreCase)) { return $index }
    }
    $wanted = Resolve-DFDesktopPathFolder -Segment $Folder
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $resolved = Resolve-DFDesktopPathFolder -Segment $segments[$index]
        if ($resolved -and [string]::Equals($resolved, $wanted, [StringComparison]::OrdinalIgnoreCase)) { return $index }
    }
    -1
}

function Add-DFDesktopPathSegment {
    <#
    .SYNOPSIS
        A Path value with one more segment: appended, or inserted before an index. Existing segments stay as written.
    .PARAMETER Value
        A Path value, as stored; may be empty.
    .PARAMETER Segment
        The segment to add.
    .PARAMETER BeforeIndex
        Insert before this segment of the split value; -1 appends.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Segment,
        [int]$BeforeIndex = -1
    )
    if ($BeforeIndex -ge 0) {
        $segments = [System.Collections.Generic.List[string]]::new([string[]]($Value -split ';'))
        $segments.Insert([Math]::Min($BeforeIndex, $segments.Count), $Segment)
        return $segments -join ';'
    }
    if ($Value -eq '') { return $Segment }
    if ($Value.EndsWith(';')) { return $Value + $Segment }
    $Value + ';' + $Segment
}

function Remove-DFDesktopPathSegment {
    <#
    .SYNOPSIS
        A Path value without one segment; the others stay as written.
    .PARAMETER Value
        A Path value, as stored.
    .PARAMETER Index
        Which segment of the split value to remove.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][int]$Index)
    $segments = [System.Collections.Generic.List[string]]::new([string[]]($Value -split ';'))
    if ($Index -ge 0 -and $Index -lt $segments.Count) { $segments.RemoveAt($Index) }
    $segments -join ';'
}

function Get-DFDesktopPathExt {
    <#
    .SYNOPSIS
        The executable extensions desktop apps try: the user PATHEXT, else the machine's, else .COM;.EXE;.BAT;.CMD.
    .OUTPUTS
        System.String per extension.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $stored = Get-DFDesktopEnvValue -Name PATHEXT
    if (-not $stored) { $stored = [Environment]::GetEnvironmentVariable('PATHEXT', 'Machine') }
    if (-not $stored) { $stored = '.COM;.EXE;.BAT;.CMD' }
    @($stored -split ';' | Where-Object { $_ })
}

function Find-DFDesktopPathOtherCopy {
    <#
    .SYNOPSIS
        Other copies of commands on the desktop PATH: the first folder, system Path then user Path, that holds each one outside a given folder.
    .DESCRIPTION
        Segments that are empty, relative, missing or resolve to -Folder are
        skipped silently. A command matches <command><ext> for each extension
        Get-DFDesktopPathExt returns.
    .PARAMETER Command
        Command names without extension.
    .PARAMETER Folder
        DotForge's own folder, never counted.
    .PARAMETER StopAtFolder
        Stop at the first segment naming -Folder: only copies that come before it count.
    .OUTPUTS
        pscustomobject per command with a copy: Command, Path (the resolved folder), Scope (System or User), Index (the user segment, -1 for System).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [Parameter(Mandatory)][string]$Folder,
        [switch]$StopAtFolder
    )
    $ours = Resolve-DFDesktopPathFolder -Segment $Folder
    $extensions = Get-DFDesktopPathExt
    $pending = [System.Collections.Generic.List[string]]::new([string[]]$Command)
    $scopes = @(
        @{ Scope = 'System'; Segments = @((Get-DFSystemPathValue) -split ';') }
        @{ Scope = 'User'; Segments = @((Get-DFUserPathValue) -split ';') }
    )
    foreach ($scope in $scopes) {
        for ($index = 0; $index -lt $scope.Segments.Count -and $pending.Count; $index++) {
            $resolved = Resolve-DFDesktopPathFolder -Segment $scope.Segments[$index]
            if (-not $resolved) { continue }
            if ($ours -and [string]::Equals($resolved, $ours, [StringComparison]::OrdinalIgnoreCase)) {
                if ($StopAtFolder) { return }
                continue
            }
            if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { continue }
            foreach ($name in @($pending)) {
                $found = $extensions | Where-Object { Test-Path -LiteralPath (Join-Path $resolved "$name$_") -PathType Leaf } | Select-Object -First 1
                if (-not $found) { continue }
                [void]$pending.Remove($name)
                [pscustomobject]@{
                    Command = $name; Path = $resolved; Scope = $scope.Scope
                    Index   = if ($scope.Scope -eq 'User') { $index } else { -1 }
                }
            }
        }
    }
}

function Get-DFDesktopPathExpected {
    <#
    .SYNOPSIS
        The desktop Path entries a record declares, with their folders expanded and the variable each lives under.
    .DESCRIPTION
        An entry lives under the xdg.vars variable whose template its path
        template starts with (whole path components, case-insensitive, the
        longest template wins).
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        pscustomobject per entry: Path (canonical), Commands, Under (variable name or $null), UnderValue (DotForge's canonical value for it or $null).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    $variables = @(if ($Tool.xdg?.vars) { $Tool.xdg.vars.PSObject.Properties | Where-Object { $_.Value } })
    foreach ($entry in @($Tool.desktopPath)) {
        $template = $entry.path.Replace([string][char]92, '/').TrimEnd('/')
        $under = $variables | Where-Object {
            $prefix = "$($_.Value)".Replace([string][char]92, '/').TrimEnd('/')
            $template.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or $template.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object { "$($_.Value)".Length } -Descending | Select-Object -First 1
        # A folder that isn't a full path stays as written (no warning): planning skips it.
        $folder = Expand-DFXdgPath $entry.path
        [pscustomobject]@{
            Path       = if ([IO.Path]::IsPathFullyQualified($folder)) { ConvertTo-DFPath $folder } else { $folder }
            Commands   = [string[]]@($entry.commands)
            Under      = if ($under) { $under.Name }
            UnderValue = if ($under) { ConvertTo-DFPath (Expand-DFXdgPath "$($under.Value)") }
        }
    }
}

function Test-DFDesktopPathGuard {
    <#
    .SYNOPSIS
        Whether a desktop Path entry's variable has another value in effect, so the entry would name a folder the tool never uses.
    .DESCRIPTION
        Checks this shell first, then the desktop value (the one in
        -DesktopValue when it holds the variable, else the user environment).
        An unset or empty value never trips it.
    .PARAMETER Entry
        One Get-DFDesktopPathExpected result.
    .PARAMETER DesktopValue
        Desktop values planned in this run, by variable name.
    .OUTPUTS
        $null, or pscustomobject: Name, Current, Where ('in this shell' or 'for desktop apps'), Suggested (the entry's folder under that value).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Entry, [hashtable]$DesktopValue)
    if (-not $Entry.Under) { return }
    $name = $Entry.Under
    $rest = $Entry.Path.Substring($Entry.UnderValue.Length)
    $inShell = [Environment]::GetEnvironmentVariable($name, 'Process')
    $inShellDiffers = $inShell -and -not ([IO.Path]::IsPathFullyQualified($inShell) -and (ConvertTo-DFPath $inShell) -eq $Entry.UnderValue)
    if ($inShellDiffers) {
        return [pscustomobject]@{ Name = $name; Current = $inShell; Where = 'in this shell'; Suggested = $inShell.TrimEnd('\', '/') + $rest }
    }
    $onDesktop = if ($DesktopValue -and $DesktopValue.ContainsKey($name)) { $DesktopValue[$name] } else { Get-DFDesktopEnvValue -Name $name }
    if ($onDesktop -and -not (Test-DFDesktopEnvMatch -Current $onDesktop -Value $Entry.UnderValue)) {
        [pscustomobject]@{ Name = $name; Current = $onDesktop; Where = 'for desktop apps'; Suggested = $onDesktop.TrimEnd('\', '/') + $rest }
    }
}

function Get-DFDesktopPathNote {
    <#
    .SYNOPSIS
        Status notes for a tool's desktop Path entries: skipped by the guard, or missing from the user Path.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        System.String per note; nothing off Windows or for a record without desktopPath (no registry read then).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    # The other-copy (shadow) check is left to Set-DFDesktopEnv: it probes every folder of the system and user
    # Path, ~170 ms per load (docs/superpowers/specs/2026-11-03-desktop-path-design.md, Status note).
    if (-not @($Tool.desktopPath).Count -or -not (Test-DFIsWindows)) { return }
    $userPath = Get-DFUserPathValue
    foreach ($entry in @(Get-DFDesktopPathExpected -Tool $Tool)) {
        $guard = Test-DFDesktopPathGuard -Entry $entry
        if ($guard) {
            "$($Tool.name)'s Path entry is skipped: $($guard.Name) is $($guard.Current) $($guard.Where), so its folder isn't under $($entry.UnderValue)"
        } elseif ((Find-DFDesktopPathSegment -Value $userPath -Folder $entry.Path) -lt 0) {
            "$($Tool.name)'s folder isn't on the desktop Path; Set-DFDesktopEnv $($Tool.name) adds it"
        }
    }
}
