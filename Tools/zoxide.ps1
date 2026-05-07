# Companion for zoxide — initialize the z function and override cd with AllScope
Invoke-Expression (& {
    $hook = if ($PSVersionTable.PSVersion.Major -lt 6) { 'prompt' } else { 'pwd' }
    (zoxide init --hook $hook powershell | Out-String)
})

if (Get-Command z -ErrorAction Ignore) {
    Set-Alias -Name cd -Value z -Scope Global -Option AllScope -Force
}
