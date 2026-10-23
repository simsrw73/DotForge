#Requires -Version 7.2

# Install-DFNerdFont's steps. Each side effect (download, copy and registry, font
# load, broadcast) is its own function, so tests mock them and never install a font.
# Design: docs/superpowers/specs/2026-10-23-fonts-design.md.

# The fonts Install-DFNerdFont offers (name in the Nerd Fonts release -> the face a terminal lists).
# CaskaydiaMono first: the Nerd Font build of Cascadia, Windows Terminal's own font.
$script:DFNerdFontChoices = [ordered]@{
    CaskaydiaMono = 'CaskaydiaMono Nerd Font'
    JetBrainsMono = 'JetBrainsMono Nerd Font'
    FiraCode      = 'FiraCode Nerd Font'
    Meslo         = 'MesloLGM Nerd Font'
    Hack          = 'Hack Nerd Font'
}

function Save-DFNerdFontArchive {
    <#
    .SYNOPSIS
        Downloads a font's zip from the latest Nerd Fonts release.
    .PARAMETER Name
        The font's name in the release (e.g. Hack).
    .PARAMETER Destination
        The folder to save it in.
    .OUTPUTS
        System.String: the zip's path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Destination)
    $zip = Join-Path $Destination "$Name.zip"
    Invoke-WebRequest -Uri "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$Name.zip" -OutFile $zip -ErrorAction Stop
    $zip
}

function Install-DFFontFile {
    <#
    .SYNOPSIS
        Installs one font file for the current user, so it survives a reboot; no admin rights.
    .DESCRIPTION
        Copies the file to the per-user fonts folder, lets packaged apps (Windows
        Terminal) read it, writes its value under the user's Fonts key (the full
        path: that value is what keeps a per-user font after a sign-in), and loads
        it into this session. A file already there and registered is skipped; one
        there without its value is registered (an installer that skipped it, such
        as FontGet).
    .PARAMETER Path
        The font file (.ttf/.otf).
    .PARAMETER FontFolder
        Where per-user fonts go. Default: $Env:LOCALAPPDATA\Microsoft\Windows\Fonts.
    .PARAMETER RegistryKey
        The user's Fonts key. Default: HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts.
    .OUTPUTS
        System.Boolean: $true when installed or repaired, $false when skipped.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$FontFolder = (Join-Path $Env:LOCALAPPDATA 'Microsoft\Windows\Fonts'),
        [string]$RegistryKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    )
    $fileName = Split-Path $Path -Leaf
    $target = Join-Path $FontFolder $fileName
    $valueName = "$([IO.Path]::GetFileNameWithoutExtension($fileName)) ($(if ($fileName -like '*.otf') { 'OpenType' } else { 'TrueType' }))"
    if (-not (Test-Path -LiteralPath $RegistryKey)) { New-Item -Path $RegistryKey -Force | Out-Null }
    $registered = (Get-ItemProperty -LiteralPath $RegistryKey -Name $valueName -ErrorAction Ignore).$valueName
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and $registered -eq $target) { return $false }

    New-DFDirectory $FontFolder
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { Copy-Item -LiteralPath $Path -Destination $target }
    $acl = Get-Acl -LiteralPath $target
    foreach ($sid in 'S-1-15-2-1', 'S-1-15-2-2') {   # ALL APPLICATION PACKAGES, ALL RESTRICTED APPLICATION PACKAGES
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'ReadAndExecute', 'Allow'))
    }
    Set-Acl -LiteralPath $target -AclObject $acl
    New-ItemProperty -LiteralPath $RegistryKey -Name $valueName -Value $target -PropertyType String -Force | Out-Null
    Add-DFFontResource -Path $target
    $true
}

function Add-DFFontResource {
    <#
    .SYNOPSIS
        Loads a font file into this sign-in session (AddFontResourceW), so running apps can use it before a reboot.
    .PARAMETER Path
        The installed font file.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Initialize-DFFontApi
    [void][DotForge.FontApi]::AddFontResourceW($Path)
}

function Send-DFFontChange {
    <#
    .SYNOPSIS
        Tells running apps the font list changed (one WM_FONTCHANGE broadcast).
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    Initialize-DFFontApi
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_FONTCHANGE, SMTO_ABORTIFHUNG, 1 s per window.
    [void][DotForge.FontApi]::SendMessageTimeoutW([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$result)
}

function Initialize-DFFontApi {
    <#
    .SYNOPSIS
        Defines the Win32 calls the font install needs, once per session.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    if ('DotForge.FontApi' -as [type]) { return }
    Add-Type -Namespace DotForge -Name FontApi -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResourceW(string lpFileName);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
}

function Test-DFFzfAvailable {
    <#
    .SYNOPSIS
        True when fzf is on PATH, so a picker can be shown.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [bool](Get-Command fzf -CommandType Application -ErrorAction Ignore)
}

function Select-DFNerdFontName {
    <#
    .SYNOPSIS
        Asks which Nerd Font to install: fzf when present, else a numbered list, else CaskaydiaMono.
    .OUTPUTS
        System.String: a key of the font list, or nothing when the picker was cancelled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $names = [string[]]@($script:DFNerdFontChoices.Keys)
    # The host first: fzf in a scheduled task or over a pipe has no one to answer it either.
    if (-not (Test-DFInteractiveHost)) {
        Write-Host "No way to ask which font: installing $($names[0]). Pass -Name to choose another."
        return $names[0]
    }
    if (Test-DFFzfAvailable) {
        return Invoke-DFPicker -List { $names }.GetNewClosure() -Header 'Select a Nerd Font to install  [Enter to install]'
    }
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $script:DFNerdFontChoices[$names[$i]]) }
    $answer = Read-Host "Font to install [1-$($names.Count), Enter for 1]"
    $choice = 0
    if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $names.Count) { return $names[$choice - 1] }
    $names[0]
}
