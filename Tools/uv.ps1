# Companion for uv — the fvenv picker, which activates a Python virtual environment.
#
# Defines: Select-UvVenv (alias fvenv).

function global:Select-UvVenv {
    <#
    .SYNOPSIS
        Fuzzy-picks a Python virtual environment below a folder and activates it.
    .DESCRIPTION
        Finds pyvenv.cfg files up to 4 levels below -Path (any venv: uv,
        python -m venv, virtualenv), previews each one (its Python version and
        how it was made), and runs the chosen venv's Activate.ps1, which sets
        VIRTUAL_ENV and PATH and defines deactivate.

        Defined by DotForge's uv companion. Requires fzf (or $Env:Picker).
    .PARAMETER Path
        The folder to search. Default: the current folder, so the venv of
        the project you are in shows at once; pass ~ to search your whole
        home folder.
    .EXAMPLE
        fvenv

        Picks a venv in the current project and activates it.
    .EXAMPLE
        fvenv ~

        Searches every venv under your home folder.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path = '.')

    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Ignore)?.ProviderPath
    if (-not $root) { Write-Warning "DotForge: no folder '$Path'."; return }
    $preview = if ($IsWindows) { 'type {}' } else { 'cat {}' }
    Invoke-DFPicker -List {
        Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter 'pyvenv.cfg' -File -Force -ErrorAction Ignore | ForEach-Object FullName
    } -Preview $preview -Header 'Select Python venv  [Enter to activate it]' -Action {
        param($cfg)
        $activate = Join-Path (Split-Path $cfg) $(if ($IsWindows) { 'Scripts' } else { 'bin' }) 'Activate.ps1'
        if (Test-Path -LiteralPath $activate) { & $activate }
        else { Write-Warning "DotForge: $(Split-Path $cfg) has no Activate.ps1." }
    }
}
Set-Alias -Name fvenv -Value Select-UvVenv -Scope Global -Force
