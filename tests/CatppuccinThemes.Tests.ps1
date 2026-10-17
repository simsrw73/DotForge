Describe 'generated catppuccin theme files' {
    BeforeAll {
        $script:Repo = Join-Path $PSScriptRoot '..'
        $script:Out = Join-Path $TestDrive 'Tools'
        & (Join-Path $script:Repo 'build' 'New-DFCatppuccinThemes.ps1') -OutputRoot $script:Out
        $script:Generated = @(Get-ChildItem $script:Out -Recurse -File | ForEach-Object { [System.IO.Path]::GetRelativePath($script:Out, $_.FullName) })
    }
    It 'writes every file' {
        $script:Generated.Count | Should -Be 24   # skim/peco/gum: 4 + license each; television: 4 x 2 + license
    }
    It 'matches the files in Tools (run build/New-DFCatppuccinThemes.ps1 after changing it)' {
        foreach ($rel in $script:Generated) {
            $repoFile = Join-Path $script:Repo 'Tools' $rel
            Test-Path $repoFile | Should -BeTrue -Because "$rel is generated"
            (Get-Content $repoFile -Raw) -replace "`r`n", "`n" | Should -BeExactly ((Get-Content (Join-Path $script:Out $rel) -Raw) -replace "`r`n", "`n") -Because "$rel is stale"
        }
    }
    It 'uses each flavor''s own colors' {
        $palette = Import-PowerShellDataFile (Join-Path $script:Repo 'build' 'catppuccin-palette.psd1')
        foreach ($flavor in 'mocha', 'macchiato', 'frappe', 'latte') {
            (Get-Content (Join-Path $script:Out 'skim' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).colors.bg | Should -Be $palette[$flavor].base
            (Get-Content (Join-Path $script:Out 'gum' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).env.GUM_FILTER_MATCH_FOREGROUND | Should -Be $palette[$flavor].red
            (Get-Content (Join-Path $script:Out 'peco' "catppuccin-$flavor.json") -Raw | ConvertFrom-Json).Style.Matched | Should -Be @($palette[$flavor].red)
            Get-Content (Join-Path $script:Out 'television' "catppuccin-$flavor" 'theme.toml') -Raw | Should -Match "background = '$($palette[$flavor].base)'"
            Get-Content (Join-Path $script:Out 'television' "catppuccin-$flavor" 'config.toml') -Raw | Should -Match "theme = `"catppuccin-$flavor`""
        }
    }
}
