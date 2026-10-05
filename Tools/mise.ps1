# Companion for mise — dev tool versions, env vars and tasks per project.
#
# The body runs whether or not mise wins project-env: it puts mise's shims on
# PATH so tools mise installed keep working under another project-env tool.
# mise honors XDG_DATA_HOME natively, so its shims live in
# <XDG_DATA_HOME>\mise\shims. Activation runs only for the role's winner, and
# is generated live every session: its output embeds the current PATH, so a
# cached copy would restore a stale one (docs/external-dependencies.md).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

Add-DFToPath (Join-Path (Get-DFXdgPath Data) 'mise\shims')

function Initialize-DFRoleProjectEnv {
    # Called by DotForge only when mise wins the project-env role.
    param([PSCustomObject]$Tool, [string]$Role)
    # The hook runs inside a DotForge function, so top-level functions the script
    # defines without global: (its `mise` wrapper, which `mise shell` needs) would
    # vanish when registration returns. Make them global; see
    # docs/external-dependencies.md.
    $activation = (& mise activate pwsh) | Out-String
    $activation -replace '(?m)^function (?!global:)', 'function global:' | Invoke-Expression
}
