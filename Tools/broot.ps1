# Companion for broot: defines br, which runs broot and moves the shell to the
# folder you leave it in (broot's :cd, alt+enter), and binds Alt+C to it when
# broot wins directory-jump. broot writes that cd to its --outcmd file as one
# POSIX-quoted line; DotForge reads only the folder from it and never runs the
# file (broot's own br does, with Invoke-Expression, which also breaks on a
# folder holding a '). The catppuccin skin that follows BrootTheme is passed
# after your conf.hjson on every run, so Set-DFToolTheme works live.
# Design: docs/superpowers/specs/2026-10-17-directory-jump-design.md.

function Get-DFBrootArgument {
    # broot's arguments for one run: the cd file ({file}), your config plus the theme's skin, then -Extra.
    param([string[]]$Extra = @())
    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add('--outcmd'); $argv.Add('{file}')
    $themeFolder = Get-DFSessionThemeValue -Name 'broot'
    $skin = if ($themeFolder) { Join-Path $themeFolder 'skin.hjson' }
    $conf = if ($Env:BROOT_CONFIG_DIR) { Join-Path $Env:BROOT_CONFIG_DIR 'conf.hjson' }
    if ($skin -and (Test-Path -LiteralPath $skin) -and $conf -and (Test-Path -LiteralPath $conf)) {
        $argv.Add('--conf'); $argv.Add("$conf;$skin")
    }
    foreach ($argument in $Extra) { $argv.Add($argument) }
    [string[]]$argv
}

function Confirm-DFBrootInstallState {
    # Before every run: broot's "install br?" state must be set, or broot offers to edit your shell
    # profiles. Setup sets it once, but the file goes with the config folder (a reset, a moved
    # BROOT_CONFIG_DIR), so it's checked here too: one Test-Path, only when br or Alt+C runs.
    param([Parameter(Mandatory)][string]$Executable)
    $configDir = if ($Env:BROOT_CONFIG_DIR) { $Env:BROOT_CONFIG_DIR } else { Join-Path $Env:APPDATA 'dystroy' 'broot' 'config' }
    $launcher = Join-Path $configDir 'launcher'
    if (Get-ChildItem -LiteralPath $launcher -Filter 'installed-v*' -File -ErrorAction Ignore) { return $true }
    $ok = $false
    try { $ok = (Invoke-DFBoundedProcess -FilePath $Executable -ArgumentList '--set-install-state', 'installed' -TimeoutSeconds 30).ExitCode -eq 0 } catch { Write-Verbose "DotForge: broot: $($_.Exception.Message)" }
    if (-not $ok) { Write-DFKeyMessage "DotForge: not running broot: its own br installer would edit your shell profiles. Run 'broot --set-install-state installed' first." }
    $ok
}

# Captured scriptblocks keep their module binding, so the global closures below can call them.
$_brootArgument = ${function:Get-DFBrootArgument}
$_installState = ${function:Confirm-DFBrootInstallState}
$_cdFile = ${function:Invoke-DFCdFileCommand}
$_brootRun = {
    param([string[]]$Extra)
    $exe = (Get-Command -Name 'broot' -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    if (-not $exe) { Write-Host 'DotForge: broot is not on PATH' -ForegroundColor Red; return $false }
    if (-not (& $_installState -Executable $exe)) { return $false }
    & $_cdFile -Executable $exe -Arguments (& $_brootArgument -Extra $Extra) -Format ShellCd
}.GetNewClosure()
$_redraw = ${function:Update-DFReadLineBuffer}

Set-Item -Path 'function:global:br' -Value ({
    <#
    .SYNOPSIS
        Runs broot, and moves the shell to the folder you leave it in.
    .DESCRIPTION
        Opens broot in the current folder with your arguments. Leave it with a
        cd (alt+enter, or :cd) and the shell changes to that folder, through
        zoxide's cd when zoxide is your navigation tool; quit without one and
        nothing changes. broot's skin follows BrootTheme (Set-DFToolTheme broot
        <flavor> switches it).

        Every argument goes to broot as it is (a folder to open, -f, -d, -p,
        ...): br is a simple function, so PowerShell doesn't take -d for
        -Debug. Defined by DotForge's broot companion. It replaces broot's own
        br, which DotForge's setup tells broot not to install.
    .EXAMPLE
        br

        Browses the current folder; alt+enter on a folder moves the shell there.
    .EXAMPLE
        br -f -d $HOME\projects

        Browses only the folders under your projects folder, with dates.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [void](& $_brootRun ([string[]]@($args)))
}.GetNewClosure())

function Initialize-DFRoleDirectoryJump {
    # Called by DotForge only when broot wins directory-jump: Alt+C opens broot on folders only.
    param($Tool, $Role)
    $run = $_brootRun
    $redraw = $_redraw
    $handler = {
        [void](& $run @('--only-folders'))
        & $redraw
    }.GetNewClosure()
    Set-DFRoleKeyHandler -Role $Role -Chord 'Alt+c' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Alt+c' -BriefDescription 'DotForge directory-jump (broot)' -Description 'Browse folders with broot and move there (DotForge)' -ScriptBlock $handler
    }
}
