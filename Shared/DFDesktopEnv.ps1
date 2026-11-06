#Requires -Version 7.2

# Desktop variables: the Windows user environment (HKCU\Environment) that programs started
# outside pwsh see. A record suggests them (desktop); Set-DFDesktopEnv writes them on request,
# never a load. See docs/superpowers/specs/2026-10-26-desktop-variables-design.md.

function Test-DFIsWindows {
    <#
    .SYNOPSIS
        Whether this is Windows, the only place desktop variables exist (a seam tests mock).
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [bool]$IsWindows
}

function Get-DFDesktopEnvKey {
    <#
    .SYNOPSIS
        The registry key holding the user environment: HKCU:\Environment.
    .DESCRIPTION
        The test suite's loader sets the script variable DFTestDesktopEnvKey
        (tests/TestSupport.ps1) to a scratch key, so no test reads or writes the
        developer's real environment. A test that imports the module can't see
        that variable, so build/Test-DFFull.ps1 also sets
        DF_TEST_DESKTOP_ENV_KEY for its run; only a key under
        HKCU:\Software\DotForge-Tests is accepted from it.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $testKey = Get-Variable -Name DFTestDesktopEnvKey -Scope Script -ValueOnly -ErrorAction Ignore
    if ($testKey) { return $testKey }
    if ($Env:DF_TEST_DESKTOP_ENV_KEY -like 'HKCU:\Software\DotForge-Tests\*') { return $Env:DF_TEST_DESKTOP_ENV_KEY }
    'HKCU:\Environment'
}

function Open-DFDesktopEnvKey {
    <#
    .SYNOPSIS
        Opens Get-DFDesktopEnvKey (an HKCU: path) as a RegistryKey; $null when it doesn't exist and -Create isn't given.
    .PARAMETER Create
        Create the key (and open it writable).
    .PARAMETER Writable
        Open it writable.
    .OUTPUTS
        Microsoft.Win32.RegistryKey, or $null.
    #>
    [CmdletBinding()]
    param([switch]$Create, [switch]$Writable)
    $subKey = (Get-DFDesktopEnvKey) -replace '^HKCU:\\', ''
    if ($Create) { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey, $true) }
    [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey, [bool]$Writable)
}

function Get-DFDesktopEnvValue {
    <#
    .SYNOPSIS
        A variable's value in the Windows user environment, unexpanded (%USERPROFILE% stays as written), or $null.
    .PARAMETER Name
        The variable.
    .OUTPUTS
        System.String, or $null when it is absent or this isn't Windows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-DFIsWindows)) { return $null }
    $key = Open-DFDesktopEnvKey
    if (-not $key) { return $null }
    try { $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Dispose() }
}

function Set-DFDesktopEnvValue {
    <#
    .SYNOPSIS
        Writes a variable to the Windows user environment, without a broadcast (Send-DFEnvironmentChange sends one for all).
    .DESCRIPTION
        A value replacing an ExpandString value stays ExpandString; a new value
        is a plain String.
    .PARAMETER Name
        The variable.
    .PARAMETER Value
        Its value.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    # A failed write throws (a terminating error): callers must never go on as if it were written.
    $key = $null
    try {
        $key = Open-DFDesktopEnvKey -Create
        $kind = if ($key.GetValueNames() -contains $Name) { $key.GetValueKind($Name) } else { [Microsoft.Win32.RegistryValueKind]::String }
        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) { $kind = [Microsoft.Win32.RegistryValueKind]::String }
        $key.SetValue($Name, $Value, $kind)
    } catch { throw } finally { if ($key) { $key.Dispose() } }
}

function Remove-DFDesktopEnvValue {
    <#
    .SYNOPSIS
        Removes a variable from the Windows user environment, without a broadcast.
    .PARAMETER Name
        The variable.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # A failed removal throws (a terminating error), like Set-DFDesktopEnvValue.
    $key = $null
    try {
        $key = Open-DFDesktopEnvKey -Writable
        if ($key) { $key.DeleteValue($Name, $false) }
    } catch { throw } finally { if ($key) { $key.Dispose() } }
}

function Invoke-DFSettingChangeBroadcast {
    <#
    .SYNOPSIS
        Tells running programs the environment changed: one WM_SETTINGCHANGE "Environment" broadcast, 2 s per window, skipping hung ones.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not ('DotForge.UserEnv' -as [type])) {
        Add-Type -Namespace DotForge -Name UserEnv -MemberDefinition '
            [DllImport("user32.dll", CharSet = CharSet.Unicode)]
            public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
                uint flags, uint timeoutMs, out UIntPtr result);'
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG
    $null = [DotForge.UserEnv]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 2000, [ref]$result)
}

function Send-DFEnvironmentChange {
    <#
    .SYNOPSIS
        Broadcasts one environment change after DotForge wrote desktop variables; nothing while tests redirect the key.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if ((Get-DFDesktopEnvKey) -ne 'HKCU:\Environment' -or -not (Test-DFIsWindows)) { return }
    Invoke-DFSettingChangeBroadcast
}

function Get-DFDesktopEnvExpected {
    <#
    .SYNOPSIS
        The desktop variables a record suggests, with the values the session uses for them.
    .DESCRIPTION
        Each name in the record's desktop list takes its xdg.vars value (a
        canonical path) or its env value, both expanded through Expand-DFXdgPath.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        pscustomobject per variable: Name, Value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    foreach ($name in @($Tool.desktop)) {
        $path = if ($Tool.xdg?.vars) { $Tool.xdg.vars.PSObject.Properties[$name]?.Value }
        $value = if ($path) { ConvertTo-DFPath (Expand-DFXdgPath $path) }
                 elseif ($Tool.env) { $plain = $Tool.env.PSObject.Properties[$name]?.Value; if ($null -ne $plain) { Expand-DFXdgPath "$plain" } }
        if ($null -ne $value) { [pscustomobject]@{ Name = $name; Value = $value } }
    }
}

function Expand-DFDesktopEnvValue {
    <#
    .SYNOPSIS
        Expands %VARIABLES% in a user-environment value the way desktop apps get them.
    .DESCRIPTION
        Each name is looked up in the user environment, then the machine's,
        then this process's (Windows' own, such as USERPROFILE) unless DotForge
        set it in this shell only: desktop apps never see those. A name found
        nowhere stays as written.
    .PARAMETER Value
        The value, as stored.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Value)
    $written = ${global:DFEnvState}?.Written
    $expanded = $Value
    foreach ($match in [regex]::Matches($Value, '%([^%]+)%')) {
        $name = $match.Groups[1].Value
        $found = Get-DFDesktopEnvValue -Name $name
        if (-not $found) { $found = [Environment]::GetEnvironmentVariable($name, 'Machine') }
        if (-not $found -and -not ($written -and $written.ContainsKey($name))) { $found = [Environment]::GetEnvironmentVariable($name, 'Process') }
        if ($found) { $expanded = $expanded.Replace($match.Value, $found) }
    }
    $expanded
}

function Test-DFDesktopEnvMatch {
    <#
    .SYNOPSIS
        Whether a value in the user environment is the one DotForge would write: %VARIABLES% expanded as desktop apps see them, full paths compared canonically, other text case-insensitively.
    .PARAMETER Current
        The value in the user environment; may be $null.
    .PARAMETER Value
        DotForge's value.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Current, [Parameter(Mandatory)][string]$Value)
    if (-not $Current) { return $false }
    $expanded = Expand-DFDesktopEnvValue -Value $Current
    if ([IO.Path]::IsPathFullyQualified($expanded) -and [IO.Path]::IsPathFullyQualified($Value)) {
        return (ConvertTo-DFPath $expanded) -eq (ConvertTo-DFPath $Value)
    }
    [string]::Equals($expanded, $Value, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DFDesktopEnvNote {
    <#
    .SYNOPSIS
        Status notes for the desktop variables a tool suggests that desktop apps don't have, or have with another value.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        System.String per note (variables, then Path entries); nothing off Windows, for a record without desktop or desktopPath, or when every value matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    if ((-not @($Tool.desktop).Count -and -not @($Tool.desktopPath).Count) -or -not (Test-DFIsWindows)) { return }
    foreach ($want in @(Get-DFDesktopEnvExpected -Tool $Tool)) {
        $current = Get-DFDesktopEnvValue -Name $want.Name
        if (-not $current) { "$($want.Name) isn't set for desktop apps; Set-DFDesktopEnv $($Tool.name) sets it" }
        elseif (-not (Test-DFDesktopEnvMatch -Current $current -Value $want.Value)) { "desktop apps see $($want.Name) = $current" }
    }
    Get-DFDesktopPathNote -Tool $Tool
}

function Get-DFDesktopEnvStatePath {
    <#
    .SYNOPSIS
        What DotForge wrote to the user environment: $XDG_STATE_HOME\dotforge\desktop-env.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath State) 'dotforge' 'desktop-env.json'
}

function Read-DFDesktopEnvState {
    <#
    .SYNOPSIS
        Reads what DotForge wrote to the user environment: Vars (variable -> { tool, value, since }) and Path (folder -> { tool, since }).
    .DESCRIPTION
        A missing file is an empty state. A file that can't be read returns
        $null (the reason goes to the verbose stream): callers then write and
        remove nothing, and each says why in its own words. The file holds
        "vars" and "path" sections; the older flat file (every key a variable)
        reads as Vars. A file naming "vars" or "path" (any case) that isn't a
        valid sectioned file is unreadable, never read as flat: its sections
        would turn into variables.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with Vars and Path hashtables, or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFDesktopEnvStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ Vars = @{}; Path = @{} } }
    try {
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -isnot [System.Collections.IDictionary]) { throw 'it holds no JSON object' }
    } catch {
        Write-Verbose "DotForge: $path can't be read: $($_.Exception.Message)"
        return $null
    }
    if (-not @($data.Keys | Where-Object { $_ -in 'vars', 'path' })) {
        return [pscustomobject]@{ Vars = ConvertTo-DFDesktopEnvRecordTable $data; Path = @{} }
    }
    $sections = @{}
    foreach ($name in $data.Keys) {
        $section = $data[$name]
        $isRecordTable = $section -is [System.Collections.IDictionary] -and
            -not @($section.Values | Where-Object { $_ -isnot [System.Collections.IDictionary] })
        if ($name -notin 'vars', 'path' -or $sections.ContainsKey($name) -or -not $isRecordTable) {
            Write-Verbose "DotForge: $path can't be read: it isn't a valid file of vars and path sections"
            return $null
        }
        $sections[$name] = $section
    }
    [pscustomobject]@{ Vars = ConvertTo-DFDesktopEnvRecordTable $sections['vars']; Path = ConvertTo-DFDesktopEnvRecordTable $sections['path'] }
}

function ConvertTo-DFDesktopEnvRecordTable {
    <#
    .SYNOPSIS
        Turns one parsed state section (key -> object) into a hashtable of key -> pscustomobject.
    .PARAMETER Section
        The parsed section; $null for a section the file doesn't hold.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($Section)
    $table = @{}
    if ($Section -is [System.Collections.IDictionary]) {
        foreach ($name in @($Section.Keys)) { $table[$name] = [pscustomobject]$Section[$name] }
    }
    $table
}

function Save-DFDesktopEnvState {
    <#
    .SYNOPSIS
        Writes what DotForge wrote to the user environment, atomically, as "vars" and "path" sections.
    .PARAMETER State
        Read-DFDesktopEnvState's object: Vars (variable -> { tool, value, since }) and Path (folder -> { tool, since }).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)
    $document = [ordered]@{ vars = $State.Vars; path = $State.Path }
    Write-DFFileAtomic -Path (Get-DFDesktopEnvStatePath) -Value ($document | ConvertTo-Json -Depth 5)
}

function Remove-DFDesktopEnvSet {
    <#
    .SYNOPSIS
        Removes the desktop variables and Path entries DotForge wrote for some tools: each only while it is still what DotForge wrote.
    .DESCRIPTION
        A variable whose value changed since is left (Changed), and said so.
        A Path entry is removed wherever it now is (the first matching
        segment, once); one already gone is Removed with nothing to write.
        Either way the record is dropped: DotForge no longer owns it. One
        that can't be removed (the registry write fails) is Failed and stays
        recorded, and a non-terminating error says why. The user Path is
        written once, one broadcast follows when anything was removed, and
        the state is saved.
    .PARAMETER Tool
        The tools; none means every tool in the state.
    .PARAMETER State
        Read-DFDesktopEnvState's object (not $null); its Vars and Path are updated and saved.
    .OUTPUTS
        DotForge.DesktopEnvResult per recorded variable and Path entry: Kind, Tool, Name, Value, Current, Action (Removed, Changed or Failed), Shadowed, Before.
    #>
    [CmdletBinding()]
    param([string[]]$Tool, [Parameter(Mandatory)][pscustomobject]$State)
    $variableRemoval = Remove-DFDesktopEnvVariable -Tool $Tool -State $State
    $pathRemoval = Remove-DFDesktopEnvPathEntry -Tool $Tool -State $State
    if ($variableRemoval.Removed -or $pathRemoval.Removed) { Send-DFEnvironmentChange }
    if ($variableRemoval.Results -or $pathRemoval.Results) { Save-DFDesktopEnvState -State $State }
    $variableRemoval.Results
    $pathRemoval.Results
    foreach ($failure in @($variableRemoval.Errors) + @($pathRemoval.Errors)) {
        Write-Error "DotForge: $failure It stays recorded; run Remove-DFDesktopEnv again once it can be written."
    }
}

function New-DFDesktopEnvRemoval {
    <#
    .SYNOPSIS
        One removal result, shaped like Set-DFDesktopEnv's (DotForge.DesktopEnvResult).
    .PARAMETER Kind
        Variable or Path.
    .PARAMETER Tool
        The recorded tool.
    .PARAMETER Name
        The variable; Path for a Path entry.
    .PARAMETER Value
        What DotForge wrote; the folder for a Path entry.
    .PARAMETER Current
        What is there now; may be $null.
    .PARAMETER Action
        Removed, Changed or Failed.
    .OUTPUTS
        DotForge.DesktopEnvResult.
    #>
    [CmdletBinding()]
    param([string]$Kind, [string]$Tool, [string]$Name, [string]$Value, [AllowNull()][string]$Current, [string]$Action)
    [pscustomobject]@{
        PSTypeName = 'DotForge.DesktopEnvResult'; Kind = $Kind; Tool = $Tool; Name = $Name; Value = $Value
        Current = if ($Current) { $Current } else { $null }; Action = $Action; Shadowed = @(); Before = $null
    }
}

function Remove-DFDesktopEnvVariable {
    <#
    .SYNOPSIS
        Removes the recorded desktop variables of some tools while unchanged, and drops their records (state not saved).
    .PARAMETER Tool
        The tools; none means all.
    .PARAMETER State
        Read-DFDesktopEnvState's object; its Vars are updated.
    .OUTPUTS
        pscustomobject: Results (DotForge.DesktopEnvResult per variable), Removed (how many were deleted) and Errors (why each Failed one failed).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console lines that are the point of the command, as in Set-DFDesktopEnv.')]
    [CmdletBinding()]
    param([string[]]$Tool, [Parameter(Mandatory)][pscustomobject]$State)
    $vars = $State.Vars
    $removed = 0
    $errors = [System.Collections.Generic.List[string]]::new()
    $results = foreach ($name in @($vars.Keys | Where-Object { -not $Tool -or $vars[$_].tool -in $Tool } | Sort-Object)) {
        $entry = $vars[$name]
        $current = Get-DFDesktopEnvValue -Name $name
        # DotForge never sets the variable Path (desktopPath entries are segments): a record naming it isn't one it wrote.
        $action = if ($name -eq 'Path') { 'Changed' }
                  elseif (-not $current -or (Test-DFDesktopEnvMatch -Current $current -Value $entry.value)) { 'Removed' } else { 'Changed' }
        if ($action -eq 'Removed' -and $current) {
            try { Remove-DFDesktopEnvValue -Name $name; $removed++ }
            catch { $action = 'Failed'; $errors.Add("couldn't remove ${name} ($($_.Exception.Message)).") }
        }
        if ($name -eq 'Path') { Write-Host "Left ${name}: DotForge never sets it as a variable, so that record isn't one it wrote." }
        elseif ($action -eq 'Changed') { Write-Host "Left ${name} = ${current}: it changed since DotForge set it to $($entry.value)." }
        if ($action -ne 'Failed') { $vars.Remove($name) }
        New-DFDesktopEnvRemoval -Kind Variable -Tool $entry.tool -Name $name -Value $entry.value -Current $current -Action $action
    }
    [pscustomobject]@{ Results = @($results); Removed = $removed; Errors = @($errors) }
}

function Remove-DFDesktopEnvPathEntry {
    <#
    .SYNOPSIS
        Removes the recorded Path entries of some tools from the user Path, one write for all, and drops their records (state not saved).
    .DESCRIPTION
        Each folder's first matching segment goes, wherever it is, but only
        one written as the folder (any spelling: case, trailing separator,
        %VARIABLES%), which is what DotForge wrote
        (Find-DFDesktopPathSegment -AsWritten). A segment that only leads
        to the folder through a link is the user's and stays. A folder no
        longer on the Path as written is Removed with nothing to write. When the Path can't be
        written, each folder that needed the write is Failed and stays
        recorded.
    .PARAMETER Tool
        The tools; none means all.
    .PARAMETER State
        Read-DFDesktopEnvState's object; its Path is updated.
    .OUTPUTS
        pscustomobject: Results (DotForge.DesktopEnvResult per folder), Removed (how many segments were deleted) and Errors (why the Failed ones failed).
    #>
    [CmdletBinding()]
    param([string[]]$Tool, [Parameter(Mandatory)][pscustomobject]$State)
    $recorded = $State.Path
    $folders = @($recorded.Keys | Where-Object { -not $Tool -or $recorded[$_].tool -in $Tool } | Sort-Object)
    if (-not $folders) { return [pscustomobject]@{ Results = @(); Removed = 0; Errors = @() } }
    $userPath = Get-DFUserPathValue
    $results = @(foreach ($folder in $folders) {
        $index = Find-DFDesktopPathSegment -Value $userPath -Folder $folder -AsWritten
        $segment = if ($index -ge 0) { ($userPath -split ';')[$index] }
        if ($index -ge 0) { $userPath = Remove-DFDesktopPathSegment -Value $userPath -Index $index }
        New-DFDesktopEnvRemoval -Kind Path -Tool $recorded[$folder].tool -Name 'Path' -Value $folder -Current $segment -Action 'Removed'
    })
    $written = @($results | Where-Object Current)
    $errors = @()
    if ($written) {
        try { Set-DFUserPathValue -Value $userPath }
        catch {
            $errors = @("couldn't write the user Path ($($_.Exception.Message)), so $(@($written.Value) -join ', ') stayed on it.")
            foreach ($item in $written) { $item.Action = 'Failed' }
        }
    }
    foreach ($item in @($results | Where-Object Action -eq 'Removed')) { $recorded.Remove($item.Value) }
    [pscustomobject]@{ Results = $results; Removed = if ($errors) { 0 } else { $written.Count }; Errors = $errors }
}
