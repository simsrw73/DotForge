BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Scoop.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Winget.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.ps1"
    . "$PSScriptRoot/../Private/Start-DFCatalogRefreshJob.ps1"
}

Describe 'Get-DFCatalogScoopDetail' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive 'scoop'
        $bucket = Join-Path $script:Root 'buckets/extras/bucket'
        New-Item -ItemType Directory -Path $bucket -Force | Out-Null
        @'
{
  "version": "0.191.6",
  "description": "code editor",
  "homepage": "https://zed.dev",
  "license": "GPL-3.0-or-later",
  "notes": ["First note.", "Second note."],
  "depends": "extras/vcredist2022",
  "suggest": { "extras": "windows-terminal" },
  "bin": [["zed.exe", "zed"], "zeditor.cmd"]
}
'@ | Set-Content (Join-Path $bucket 'zed.json')
    }

    It 'reads the full manifest for a bucket-qualified id' {
        $d = Get-DFCatalogScoopDetail -PackageId 'extras/zed' -ScoopRoot $script:Root
        $d.PSObject.TypeNames[0] | Should -Be 'DotForge.ToolSourceDetail'
        $d.Notes | Should -Be 'First note. Second note.'
        $d.Dependencies | Should -Be @('extras/vcredist2022')
        $d.InstallHint | Should -Be 'scoop install extras/zed'
        $d.Extra['bin'] | Should -Be @('zed', 'zeditor.cmd')
        $d.Extra['suggest'] | Should -Be @('extras: windows-terminal')
    }

    It 'searches all buckets for a bare name' {
        $d = Get-DFCatalogScoopDetail -PackageId 'zed' -ScoopRoot $script:Root
        $d.PackageId | Should -Be 'extras/zed'
    }

    It 'returns null for a missing manifest' {
        Get-DFCatalogScoopDetail -PackageId 'extras/nope' -ScoopRoot $script:Root | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DFCatalogWingetShow' {
    It 'parses Key: value output including indented continuations' {
        $lines = @(
            'Found Zed [Zed.Zed]'
            'Version: 0.191.6'
            'Publisher: Zed Industries, Inc.'
            'Moniker: zed'
            'Description:'
            '  A high-performance editor.'
            '  Built in Rust.'
            'Homepage: https://zed.dev'
            'License: GPL-3.0'
            'Release Notes Url: https://zed.dev/releases'
            'Tags:'
            '  editor'
            '  rust'
            'Installer:'
            '  Installer Type: zip'
        )
        $d = ConvertFrom-DFCatalogWingetShow -Lines $lines -PackageId 'Zed.Zed'
        $d.Publisher | Should -Be 'Zed Industries, Inc.'
        $d.ReleaseNotesUrl | Should -Be 'https://zed.dev/releases'
        $d.Tags | Should -Be @('editor', 'rust')
        $d.Notes | Should -Be 'A high-performance editor. Built in Rust.'
        $d.InstallHint | Should -Be 'winget install --id Zed.Zed --exact'
    }

    It 'returns null when no Key: value lines are present (package not found)' {
        ConvertFrom-DFCatalogWingetShow -Lines @('No package found matching input criteria.') -PackageId 'X.Y' |
            Should -BeNullOrEmpty
    }
}

Describe 'winget Detail hook wiring' {
    BeforeEach {
        $script:SavedXdgCache = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = Join-Path $TestDrive 'cache'
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdgCache }

    It 'caches winget show output through the detail engine' {
        Mock Invoke-DFCatalogWingetShowCli { @('Version: 1.0', 'Publisher: P') }
        $d1 = Get-DFCatalogWingetDetail -PackageId 'X.Y'
        $d2 = Get-DFCatalogWingetDetail -PackageId 'X.Y'
        $d2.Publisher | Should -Be 'P'
        Should -Invoke Invoke-DFCatalogWingetShowCli -Times 1 -Exactly
    }
}
