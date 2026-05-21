# Companion for scoop — dot-sourced by Register-DFTool when scoop is registered.
# Invoke-Expression is required by scoop-search's hook registration pattern.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
param()

# Scoop requires git for bucket operations (scoop bucket add, scoop update, etc.)
if (-not (Get-Command git -ErrorAction Ignore)) {
    Write-Warning 'DotForge: git is not installed — scoop bucket operations will fail. Fix: scoop install git'
}

# If scoop-search is installed, hook it as the default search provider.
# It is dramatically faster than built-in scoop search.
# To install: scoop install scoop-search
if (Get-Command scoop-search -ErrorAction Ignore) {
    Invoke-Expression (& scoop-search --hook | Out-String)
} else {
    Write-Verbose 'DotForge: scoop-search not found — install for faster search: scoop install scoop-search'
}
