# Companion for gsudo — please (re-run last history entry elevated)
# [scriptblock]::Create() preserves pipes, semicolons, and compound expressions
# that would break if passed as a plain string argument to gsudo.
function global:please {
    [CmdletBinding()]
    param()
    $last = (Get-History -Count 1).CommandLine
    if (-not $last) {
        Write-Warning 'DotForge: no command history to elevate'
        return
    }
    gsudo ([scriptblock]::Create($last))
}
