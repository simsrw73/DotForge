#Requires -Version 7.0

function Select-DFPackage {
    <#
    .SYNOPSIS
        Fuzzy-browse every locally cached catalog package with fzf; Enter shows
        the trifle info card for the selection.
    .DESCRIPTION
        Reads only local caches (scoop/winget indexes, cached web queries, the
        installed snapshot) so the list opens instantly — run
        Update-DFPackageCache (or any first trifle query) to populate it.
    .PARAMETER Source
        Restrict the list to packages known to these catalogs.
    .EXAMPLE
        ftrifle
        Browse all locally known packages; Enter renders the info card.
    .OUTPUTS
        None — the selection is rendered via Find-DFPackage.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('scoop', 'winget', 'choco', 'npm', 'pypi', 'crates', 'psgallery')]
        [string[]]$Source
    )

    $packages = @(Get-DFCatalogLocalPackages)
    if ($Source) {
        $packages = @($packages | Where-Object {
            @($_.Sources -split ',') | Where-Object { $_ -in $Source }
        })
    }
    if (-not $packages) {
        Write-Warning 'DotForge: no local catalog data yet — run Update-DFPackageCache or a first trifle query.'
        return
    }

    $lines = @($packages | ForEach-Object { "$($_.Name)`t$($_.Sources)`t$($_.Description)" })

    Invoke-DFPicker -List { $lines }.GetNewClosure() `
        -Header 'Select package [Enter: info card]' `
        -Delimiter "`t" -WithNth '1,3' `
        -Parse { ($_ -split "`t")[0] } `
        -Action { param($name) Find-DFPackage -Query $name }
}

Set-Alias -Name ftrifle -Value Select-DFPackage -Scope Global -Force
