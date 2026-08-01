[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

function global:Start-DFInshellisense {
    is -c *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Invoke-Expression (is init pwsh | Out-String)
}
