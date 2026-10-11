# Companion for npm — the fns picker, which runs a package.json script.
#
# Defines: Select-NpmScript (alias fns).

function global:Select-NpmScript {
    <#
    .SYNOPSIS
        Fuzzy-picks a script from the nearest package.json and runs it with the project's package manager.
    .DESCRIPTION
        Finds package.json in the current folder or the nearest parent, lists
        its scripts with each one's command line in the preview, and runs the
        chosen script from the package's folder. The manager is the project's
        own, judged by the lockfile next to package.json: pnpm for
        pnpm-lock.yaml, bun for bun.lock or bun.lockb, yarn for yarn.lock,
        else npm.

        Defined by DotForge's npm companion. Requires fzf (or $Env:Picker).
    .EXAMPLE
        fns

        Picks a script such as build or test and runs it.
    .OUTPUTS
        The script's output.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()

    $dir = $PWD.ProviderPath
    while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'package.json'))) { $dir = Split-Path $dir -Parent }
    if (-not $dir) { Write-Warning 'DotForge: no package.json here or in any parent folder.'; return }

    $scripts = (Get-Content -LiteralPath (Join-Path $dir 'package.json') -Raw | ConvertFrom-Json).PSObject.Properties['scripts']?.Value
    $lines = @(if ($scripts) { $scripts.PSObject.Properties | ForEach-Object { "$($_.Name)`t$($_.Value)" } })
    $lockfiles = [ordered]@{ 'pnpm-lock.yaml' = 'pnpm'; 'bun.lock' = 'bun'; 'bun.lockb' = 'bun'; 'yarn.lock' = 'yarn' }
    $manager = @($lockfiles.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $dir $_) } | ForEach-Object { $lockfiles[$_] })[0] ?? 'npm'

    Invoke-DFPicker -List { $lines } -Delimiter "`t" -WithNth '1' -Preview 'echo {2..}' -PreviewWindow 'down:3:wrap' `
        -Header "Select script  [Enter to $manager run it]" -Parse { ($_ -split "`t")[0] } -Action {
            param($name)
            Push-Location -LiteralPath $dir
            try { & $manager run $name } finally { Pop-Location }
        }
}
Set-Alias -Name fns -Value Select-NpmScript -Scope Global -Force
