#Requires -Version 7.0

$script:DFToolDb = $null

function script:Import-DFToolDb {
    <#
    .SYNOPSIS
        Loads Tools/*.json files into a cached hashtable keyed by tool name.
        Validates each file with Test-DFToolSchema; invalid files are skipped with a warning.
    .PARAMETER ToolsPath
        Path to the tools directory. Defaults to the module's Tools/ folder.
        Pass an explicit path in tests to control which JSON files are loaded.
        Supplying this parameter always forces a fresh, uncached read and never
        populates the shared cache -- only calls using the default location
        participate in caching, so a caller with its own directory never sees
        (or clobbers) another caller's registry.
    .PARAMETER Force
        Clears the cache and reloads from disk. Has no effect when -ToolsPath is also
        supplied -- that call is always uncached regardless of -Force.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ToolsPath = (Join-Path $PSScriptRoot '../Tools'),
        [switch]$Force
    )

    $explicitToolsPath = $PSBoundParameters.ContainsKey('ToolsPath')

    if (-not $explicitToolsPath -and -not $Force -and $script:DFToolDb) { return $script:DFToolDb }

    $db = @{}

    if (Test-Path $ToolsPath -PathType Container) {
        Get-ChildItem $ToolsPath -Filter '*.json' -ErrorAction Ignore |
            ForEach-Object {
                try {
                    $tool = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $errors = @()
                    if (Test-DFToolSchema -Tool $tool -Errors ([ref]$errors)) {
                        $db[$tool.name] = $tool
                    } else {
                        Write-Warning "DotForge: $($_.Name) schema errors: $($errors -join '; ')"
                    }
                } catch {
                    Write-Warning "DotForge: Failed to parse $($_.Name): $($_.Exception.Message)"
                }
            }
    }

    if (-not $explicitToolsPath) { $script:DFToolDb = $db }
    return $db
}
