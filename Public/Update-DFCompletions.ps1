#Requires -Version 7.0

function Update-DFCompletions {
    <#
    .SYNOPSIS
        Invalidates and regenerates dynamic completion caches for known CLI tools.
        Tools not currently on PATH have their cache cleared but are not regenerated.
    .PARAMETER Name
        Limit to specific tool names. If omitted, all dynamic-completion tools are updated.
    .PARAMETER ToolsPath
        Override the tools directory (used in tests).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [string]$ToolsPath
    )

    $dbArgs = if ($ToolsPath) { @{ ToolsPath = $ToolsPath } } else { @{} }
    $db = Import-DFToolDb @dbArgs

    $cacheDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'completions'

    $tools = $db.Values | Where-Object {
        $cp = $_.PSObject.Properties['completions']
        $cp -and $cp.Value -and $cp.Value.PSObject.Properties['type']?.Value -eq 'dynamic'
    }

    if ($Name) {
        $tools = $tools | Where-Object { $_.name -in $Name }
    }

    foreach ($tool in $tools) {
        $cacheFile = Join-Path $cacheDir "$($tool.name).ps1"
        Remove-Item $cacheFile -Force -ErrorAction Ignore

        $exe    = $tool.PSObject.Properties['executable']?.Value
        $exeCmd = if ($exe) { Get-Command $exe -ErrorAction Ignore } else { $null }

        if (-not $exeCmd) {
            Write-Verbose "DotForge: $($tool.name) not on PATH — cache cleared, skipping regeneration"
            continue
        }

        $genCmd = $tool.completions.PSObject.Properties['command']?.Value
        if ($genCmd) {
            $capturedCmd = $genCmd
            Get-DFCachedCompletion `
                -CacheKey $tool.name `
                -ExePath  $exeCmd.Path `
                -Generate { & ([scriptblock]::Create($capturedCmd)) }.GetNewClosure()
            Write-Host "✓ $($tool.name) completions updated" -ForegroundColor Green
        }
    }
}
