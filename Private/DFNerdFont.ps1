#Requires -Version 7.2

# Whether icons are on: the NerdFont setting, else whether a Nerd Font is installed.
# Design: docs/superpowers/specs/2026-10-23-fonts-design.md.
# Whether a Nerd Font is installed, read once per session ($null: not read yet).
$script:DFNerdFontPresent = $null
$script:DFNerdFontNoticed = $false
# Whether a tool left its icons out this session (Test-DFIconsOn said no): only then does the load say so.
$script:DFIconsWithheld = $false

function Get-DFFontRegistryEntry {
    <#
    .SYNOPSIS
        The fonts registered for this user and for the machine whose names match a pattern, with their files.
    .DESCRIPTION
        Reads the HKCU and HKLM "Windows NT\CurrentVersion\Fonts" keys, HKCU first.
        A per-user value holds the font file's full path; a machine value holds a
        file name under $Env:windir\Fonts. Only these keys say what survives a
        reboot (fonts loaded with AddFontResource alone are gone after it). A
        machine can list hundreds of fonts, so names are filtered before anything
        else is read, and entries stream (a caller may stop at the first). Nothing
        off Windows.
    .PARAMETER Pattern
        A regex the value name must match.
    .OUTPUTS
        PSCustomObject { Name; Path }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pattern)
    if (-not $IsWindows) { return }
    $fontsDir = Join-Path $Env:windir 'Fonts'
    foreach ($hive in [Microsoft.Win32.Registry]::CurrentUser, [Microsoft.Win32.Registry]::LocalMachine) {
        $key = $hive.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\Fonts')
        if (-not $key) { continue }
        try {
            foreach ($name in @($key.GetValueNames()) -match $Pattern) {
                $value = [string]$key.GetValue($name)
                if (-not $value) { continue }
                $path = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $fontsDir $value }
                [pscustomobject]@{ Name = $name; Path = $path }
            }
        } finally { $key.Dispose() }
    }
}

function Get-DFNerdFontFace {
    <#
    .SYNOPSIS
        The faces of the installed Nerd Fonts whose files exist.
    .DESCRIPTION
        Only Nerd Font names (Test-DFNerdFontName) have their file checked, so a
        font deleted by hand without its registry value doesn't count.
    .PARAMETER First
        Stop at the first one: enough to know a Nerd Font is installed.
    .OUTPUTS
        System.String[]: distinct face names, e.g. "Hack Nerd Font".
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$First)
    # A cheap regex narrows the names before Test-DFNerdFontName decides. One pipeline,
    # so Select-Object -First stops the registry read at the first installed one.
    $installed = { (Test-DFNerdFontName -Name $_.Name) -and [IO.File]::Exists($_.Path) }
    $entries = if ($First) {
        Get-DFFontRegistryEntry -Pattern '(?i)nerd|nf' | Where-Object $installed | Select-Object -First 1
    } else {
        Get-DFFontRegistryEntry -Pattern '(?i)nerd|nf' | Where-Object $installed
    }
    [string[]]@($entries | ForEach-Object { ConvertTo-DFFontFaceName -Name $_.Name } | Select-Object -Unique)
}

function Test-DFNerdFontPresent {
    <#
    .SYNOPSIS
        True when a Nerd Font is installed, read once per session; always true off Windows, where DotForge can't tell.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $true }
    if ($null -eq $script:DFNerdFontPresent) { $script:DFNerdFontPresent = [bool]@(Get-DFNerdFontFace -First).Count }
    $script:DFNerdFontPresent
}
function Test-DFIconsOn {
    <#
    .SYNOPSIS
        True when tools may draw Nerd Font icons: the NerdFont setting, else whether a Nerd Font is installed.
    .DESCRIPTION
        The one place that decides it. Role words, picker previews and records
        marked nerdFont: "required" all follow it.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $setting = Get-DFConfig NerdFont
    if ($null -ne $setting) { return [bool]$setting }
    # Asked only where icons would be drawn, so a "no" means something was left out.
    $on = Test-DFNerdFontPresent
    if (-not $on) { $script:DFIconsWithheld = $true }
    $on
}

function Reset-DFIconsOn {
    <#
    .SYNOPSIS
        Forgets this session's Nerd Font detection, so the next check reads the registry again.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $script:DFNerdFontPresent = $null
    $script:DFNerdFontNoticed = $false
    $script:DFIconsWithheld = $false
}

function Get-DFNerdFontChange {
    <#
    .SYNOPSIS
        Whether a Nerd Font is installed now, and whether it appeared since the last load.
    .DESCRIPTION
        Compares with $XDG_STATE_HOME\dotforge\nerd-font.json ({ "present": bool }),
        written only when the answer changes. With no file yet, this load is the
        baseline: NewlyPresent is $false, so a user who already had a Nerd Font
        never hears about it.
    .OUTPUTS
        PSCustomObject { Present; Faces; NewlyPresent }.
    #>
    [CmdletBinding()]
    param()
    $present = Test-DFNerdFontPresent
    $stateFile = Join-Path (Get-DFXdgPath State) 'dotforge' 'nerd-font.json'
    $previous = $null
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { $previous = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).PSObject.Properties['present']?.Value } catch { $previous = $null }
    }
    if ($previous -ne $present) { Write-DFFileAtomic -Path $stateFile -Value (@{ present = $present } | ConvertTo-Json -Compress) }
    [pscustomobject]@{
        Present      = $present
        # The face names only when they are shown: listing them all costs more than detecting one.
        Faces        = if ($present -and $previous -eq $false) { [string[]]@(Get-DFNerdFontFace) } else { [string[]]@() }
        NewlyPresent = $present -and $previous -eq $false
    }
}

function Write-DFNerdFontNotice {
    <#
    .SYNOPSIS
        At the end of a load, says why icons are off, or names a Nerd Font that has just appeared.
    .DESCRIPTION
        Once per session, Windows only. While no Nerd Font is installed, NerdFont
        isn't set and a requested tool left its icons out, every load warns that
        icons are off and how to fix it. When a Nerd
        Font has appeared since the last load (Get-DFNerdFontChange), a one-time note
        says to select it in the terminal, which DotForge can't do or see.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if (-not $IsWindows -or $script:DFNerdFontNoticed) { return }
    $script:DFNerdFontNoticed = $true
    $change = Get-DFNerdFontChange
    if ($change.NewlyPresent) {
        # A text font to select: not the symbols-only one, and the plain build before Mono or Propo.
        $faces = @($change.Faces)
        $face = @($faces | Where-Object { $_ -notmatch 'Symbols' -and $_ -notmatch '\b(Mono|Propo|NFM|NFP)$' }) + @($faces | Where-Object { $_ -notmatch 'Symbols' }) + $faces | Select-Object -First 1
        Write-Host "DotForge: Nerd Font installed: $face. Select it as your terminal's font to see icons." -ForegroundColor Cyan
    }
    if (-not $change.Present -and $script:DFIconsWithheld -and $null -eq (Get-DFConfig NerdFont)) {
        Write-Warning 'DotForge: No Nerd Font installed, so icons are off. Run Install-DFNerdFont, or set NerdFont = $true if your terminal already has one.'
    }
}
