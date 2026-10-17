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

# Captured scriptblocks keep their module binding, so the global closures below can call them.
$_brootArgument = ${function:Get-DFBrootArgument}
$_cdFile = ${function:Invoke-DFCdFileCommand}
$_brootRun = {
    param([string[]]$Extra)
    $exe = (Get-Command -Name 'broot' -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
    if (-not $exe) { Write-Host 'DotForge: broot is not on PATH' -ForegroundColor Red; return $false }
    & $_cdFile -Executable $exe -Arguments (& $_brootArgument -Extra $Extra) -Format ShellCd
}.GetNewClosure()

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

        Defined by DotForge's broot companion. It replaces broot's own br,
        which DotForge's setup tells broot not to install.
    .PARAMETER Arguments
        Arguments passed to broot (a folder to open, --only-folders, ...).
    .EXAMPLE
        br

        Browses the current folder; alt+enter on a folder moves the shell there.
    .EXAMPLE
        br -f ~/projects

        Browses only the folders under ~/projects.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())
    [void](& $_brootRun $Arguments)
}.GetNewClosure())

function Initialize-DFRoleDirectoryJump {
    # Called by DotForge only when broot wins directory-jump: Alt+C opens broot on folders only.
    param($Tool, $Role)
    $run = $_brootRun
    $handler = {
        [void](& $run @('--only-folders'))
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }.GetNewClosure()
    Set-DFRoleKeyHandler -Role $Role -Chord 'Alt+c' -Tool $Tool.name -Bind {
        Set-PSReadLineKeyHandler -Chord 'Alt+c' -BriefDescription 'DotForge directory-jump (broot)' -Description 'Browse folders with broot and move there (DotForge)' -ScriptBlock $handler
    }
}
