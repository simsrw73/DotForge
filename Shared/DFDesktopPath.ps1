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
    $key = Open-DFDesktopEnvKey -Create
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') {
            $existing = $key.GetValueKind('Path')
            if ($existing -eq [Microsoft.Win32.RegistryValueKind]::String) { $kind = $existing }
        }
        $key.SetValue('Path', $Value, $kind)
    } finally { $key.Dispose() }
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
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $null }
    try {
        $expanded = (Expand-DFDesktopEnvValue -Value $Segment.Trim()).Trim('"')
        if (-not [IO.Path]::IsPathFullyQualified($expanded)) { return $null }
        $folder = ConvertTo-DFPath $expanded
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
    $wanted = Resolve-DFDesktopPathFolder -Segment $Folder
    if (-not $wanted) { return -1 }
    $segments = $Value -split ';'
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
