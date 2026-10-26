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
        developer's real environment.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $testKey = Get-Variable -Name DFTestDesktopEnvKey -Scope Script -ValueOnly -ErrorAction Ignore
    if ($testKey) { $testKey } else { 'HKCU:\Environment' }
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
    $key = Open-DFDesktopEnvKey -Create
    try {
        $kind = if ($key.GetValueNames() -contains $Name) { $key.GetValueKind($Name) } else { [Microsoft.Win32.RegistryValueKind]::String }
        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) { $kind = [Microsoft.Win32.RegistryValueKind]::String }
        $key.SetValue($Name, $Value, $kind)
    } finally { $key.Dispose() }
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
    $key = Open-DFDesktopEnvKey -Writable
    if (-not $key) { return }
    try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() }
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

function Test-DFDesktopEnvMatch {
    <#
    .SYNOPSIS
        Whether a value in the user environment is the one DotForge would write (%VARIABLES% expanded, case-insensitive).
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
    [string]::Equals([Environment]::ExpandEnvironmentVariables($Current), $Value, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DFDesktopEnvNote {
    <#
    .SYNOPSIS
        Status notes for the desktop variables a tool suggests that desktop apps don't have, or have with another value.
    .PARAMETER Tool
        A normalized tool record.
    .OUTPUTS
        System.String per note; nothing off Windows, for a record without desktop, or when every value matches.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Tool)
    if (-not @($Tool.desktop).Count -or -not (Test-DFIsWindows)) { return }
    foreach ($want in @(Get-DFDesktopEnvExpected -Tool $Tool)) {
        $current = Get-DFDesktopEnvValue -Name $want.Name
        if (-not $current) { "$($want.Name) isn't set for desktop apps; Set-DFDesktopEnv $($Tool.name) sets it" }
        elseif (-not (Test-DFDesktopEnvMatch -Current $current -Value $want.Value)) { "desktop apps see $($want.Name) = $current" }
    }
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
        Reads the desktop variables DotForge wrote: variable -> { tool, value, since }.
    .DESCRIPTION
        A missing file is an empty table. A file that can't be read warns and
        returns $null: callers then write and remove nothing, since they
        couldn't record it.
    .OUTPUTS
        System.Collections.Hashtable, or $null.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFDesktopEnvStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -isnot [System.Collections.IDictionary]) { throw 'it holds no JSON object' }
    } catch {
        Write-Warning "DotForge: $path can't be read ($($_.Exception.Message)), so desktop variables can't be recorded. Fix or delete it."
        return $null
    }
    $table = @{}
    foreach ($name in @($data.Keys)) { $table[$name] = [pscustomobject]$data[$name] }
    $table
}

function Save-DFDesktopEnvState {
    <#
    .SYNOPSIS
        Writes the desktop variables DotForge wrote, atomically.
    .PARAMETER State
        Variable -> { tool, value, since }.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$State)
    Write-DFFileAtomic -Path (Get-DFDesktopEnvStatePath) -Value ($State | ConvertTo-Json -Depth 5)
}

function Remove-DFDesktopEnvSet {
    <#
    .SYNOPSIS
        Removes the desktop variables DotForge wrote for some tools: each only while its value is still the one DotForge wrote.
    .DESCRIPTION
        A variable whose value changed since is left (Changed), and said so.
        Either way its record is dropped: DotForge no longer owns it. One
        broadcast follows when anything was removed; the state is saved.
    .PARAMETER Tool
        The tools; none means every tool in the state.
    .PARAMETER State
        Read-DFDesktopEnvState's table (not $null); updated and saved.
    .OUTPUTS
        pscustomobject per recorded variable: Tool, Name, Value, Current, Action (Removed or Changed).
    #>
    [CmdletBinding()]
    param([string[]]$Tool, [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$State)
    $names = @($State.Keys | Where-Object { -not $Tool -or $State[$_].tool -in $Tool } | Sort-Object)
    if (-not $names) { return }
    $removed = 0
    $results = foreach ($name in $names) {
        $entry = $State[$name]
        $current = Get-DFDesktopEnvValue -Name $name
        $action = if (-not $current -or (Test-DFDesktopEnvMatch -Current $current -Value $entry.value)) { 'Removed' } else { 'Changed' }
        if ($action -eq 'Removed' -and $current) { Remove-DFDesktopEnvValue -Name $name; $removed++ }
        if ($action -eq 'Changed') { Write-Host "Left ${name} = ${current}: it changed since DotForge set it to $($entry.value)." }
        $State.Remove($name)
        [pscustomobject]@{ PSTypeName = 'DotForge.DesktopEnvResult'; Tool = $entry.tool; Name = $name; Value = $entry.value; Current = $current; Action = $action }
    }
    if ($removed) { Send-DFEnvironmentChange }
    Save-DFDesktopEnvState -State $State
    $results
}
