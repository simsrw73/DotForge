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
    [CmdletBinding()]
    param()
    $last = (Get-History -Count 1).CommandLine
    if (-not $last) {
        Write-Warning 'DotForge: no command history to elevate'
        return
    }
    sudo ([scriptblock]::Create($last))
}
