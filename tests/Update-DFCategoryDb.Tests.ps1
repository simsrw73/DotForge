BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFCategoryDbSchema.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFCategoryDbDownload.ps1"
    . "$PSScriptRoot/../Public/Update-DFCategoryDb.ps1"

    function New-FakeDoc {
        param($ToolCount = 1)
        [pscustomobject]@{
            schemaVersion = 1
            updated       = '2026-07-05'
            taxonomy      = [pscustomobject]@{ function = @('search'); worksWith = @('text') }
            tools         = [pscustomobject]@{ ripgrep = [pscustomobject]@{ function = @('search'); interface = 'cli' } }
        }
    }
}

Describe 'Update-DFCategoryDb' {
    BeforeEach {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        # Each It needs its own directory: TestDrive is only reset once per
        # Describe (at block teardown), not between individual It blocks, so a
        # fixed 'data' subfolder here would leak state (e.g. a file written by
        # an earlier It) into later Its that assert on a clean slate.
        $Env:XDG_DATA_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString()) 'data'
        $script:DestPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-categories.json'
    }
    AfterEach { $Env:XDG_DATA_HOME = $script:SavedDataHome }

    It 'downloads, validates, and atomically writes the destination' {
        Mock Invoke-DFCategoryDbDownload { New-FakeDoc }
        Update-DFCategoryDb -Confirm:$false
        Test-Path $script:DestPath | Should -BeTrue
        (Get-Content $script:DestPath -Raw | ConvertFrom-Json).tools.ripgrep.function | Should -Contain 'search'
        Get-ChildItem (Split-Path $script:DestPath) -Filter '*.tmp.*' | Should -BeNullOrEmpty
    }

    It 'leaves no file behind on -WhatIf' {
        Mock Invoke-DFCategoryDbDownload { New-FakeDoc }
        Update-DFCategoryDb -WhatIf
        Test-Path $script:DestPath | Should -BeFalse
    }

    It 'warns and writes nothing when the download fails' {
        Mock Invoke-DFCategoryDbDownload { throw 'network down' }
        $w = $null
        Update-DFCategoryDb -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'failed to download'
        Test-Path $script:DestPath | Should -BeFalse
    }

    It 'warns and leaves the existing copy untouched when validation fails' {
        New-DFDirectory (Split-Path $script:DestPath)
        # -NoNewline: Set-Content appends a trailing newline by default, which
        # would make the byte-for-byte "untouched" comparison below fail even
        # when the file was correctly left alone.
        Set-Content -Path $script:DestPath -Value 'existing-good-content' -NoNewline
        Mock Invoke-DFCategoryDbDownload {
            [pscustomobject]@{ schemaVersion = 1; taxonomy = [pscustomobject]@{ function = @(); worksWith = @() }; tools = [pscustomobject]@{} }
        }
        $w = $null
        Update-DFCategoryDb -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'validation'
        Get-Content $script:DestPath -Raw | Should -Be 'existing-good-content'
    }

    It 'warns when XDG_DATA_HOME is unset' {
        $Env:XDG_DATA_HOME = $null
        Mock Invoke-DFCategoryDbDownload { New-FakeDoc }
        $w = $null
        Update-DFCategoryDb -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'XDG_DATA_HOME'
    }
}
