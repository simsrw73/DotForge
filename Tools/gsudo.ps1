# Companion for gsudo — establish precedence, wire sudo, and provide please.
# Scoop commonly exposes gsudo through a shim directory that trails Windows on
# PATH, allowing Windows 11's sudo.exe to win. Prefer that resolved shim before
# defining the session alias so both PowerShell and child processes use gsudo.
$resolvedGsudo = Get-Command gsudo.exe -ErrorAction Ignore
$installedSudo = @(Get-Command sudo -All -ErrorAction Ignore |
    Where-Object { $_.Path }) | Select-Object -First 1
if ($resolvedGsudo -and $installedSudo -and $Env:WINDIR) {
    $windowsRoot = $Env:WINDIR.TrimEnd('\')
    if ($installedSudo.Path -like "$windowsRoot\*") {
        Add-DFToPath (Split-Path $resolvedGsudo.Path -Parent) -Prepend
    }
}
Set-Alias -Name sudo -Value gsudo -Scope Global -Force

# please re-runs the last history entry elevated.
# [scriptblock]::Create() preserves pipes, semicolons, and compound expressions
# that would break if passed as a plain string argument to sudo.
function global:please {
    <#
    .SYNOPSIS
        Re-runs the previous command elevated, through gsudo.
    .DESCRIPTION
        Takes the last entry in this session's history (Get-History) and runs
        it again through gsudo, which shows a UAC prompt. Pipes, semicolons and
        other compound syntax are preserved. Warns and does nothing when there
        is no history yet.

        The command runs in a new elevated PowerShell process, so variables
        and functions from the current session are not available to it.

        Defined by DotForge's gsudo companion, which also aliases sudo to gsudo
        and, when Windows' built-in sudo.exe would otherwise win, moves gsudo's
        directory to the front of PATH.
    .EXAMPLE
        Remove-Item C:\Windows\Temp\old.log
        please

        The first command fails with access denied; please runs it again elevated.
    .OUTPUTS
        Whatever the elevated command writes.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    $last = (Get-History -Count 1).CommandLine
    if (-not $last) {
        Write-Warning 'DotForge: no command history to elevate'
        return
    }
    sudo ([scriptblock]::Create($last))
}
