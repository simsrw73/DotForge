# Companion for inshellisense — defines Start-DFInshellisense, which the
# tab-completion hook calls when inshellisense wins. Registering inshellisense
# alone does not start it because its role membership is opt-in. Invoke-Expression
# is required by inshellisense's init pattern.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

function global:Start-DFInshellisense {
    <#
    .SYNOPSIS
        Starts an inshellisense session in this shell unless one is already running.
    .DESCRIPTION
        Checks is -c, which succeeds inside an existing inshellisense session,
        and returns without doing anything in that case. Otherwise it runs the
        script printed by is init pwsh, which starts inshellisense's IDE-style
        autocomplete in the current shell.

        DotForge calls this when inshellisense wins the tab-completion role.
        Defined by DotForge's inshellisense companion; requires the is command.
    .EXAMPLE
        Start-DFInshellisense

        Starts inshellisense in the current shell.
    .OUTPUTS
        None.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/completion.md
    #>
    is -c *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Invoke-Expression (is init pwsh | Out-String)
}

function Initialize-DFRoleTabCompletion {
    param($Tool, $Role)
    Start-DFInshellisense
}
