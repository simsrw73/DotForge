BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolIdentityGuideSchema.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolIdentityGuideDownload.ps1"
    . "$PSScriptRoot/../Public/Update-DFToolIdentityGuide.ps1"

    function New-FakeGuideDoc {
        [pscustomobject]@{
            schemaVersion = 1
            updated       = '2026-07-06'
            tools         = [pscustomobject]@{
                ripgrep = [pscustomobject]@{ packages = [pscustomobject]@{ scoop = 'ripgrep' }; linkedVia = 'curated' }
            }
        }
    }
}

Describe 'Update-DFToolIdentityGuide' {
    BeforeEach {
        $script:SavedDataHome = $Env:XDG_DATA_HOME
        # Each It needs its own directory: TestDrive is only reset once per
        # Describe (at block teardown), not between individual It blocks, so a
        # fixed 'data' subfolder here would leak state (e.g. a file written by
        # an earlier It) into later Its that assert on a clean slate.
        $Env:XDG_DATA_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString()) 'data'
        $script:DestPath = Join-Path $Env:XDG_DATA_HOME 'dotforge/tool-identities.json'
    }
    AfterEach { $Env:XDG_DATA_HOME = $script:SavedDataHome }

    It 'downloads, validates, and atomically writes the destination' {
        Mock Invoke-DFToolIdentityGuideDownload { New-FakeGuideDoc }
        Update-DFToolIdentityGuide -Confirm:$false
        Test-Path $script:DestPath | Should -BeTrue
        (Get-Content $script:DestPath -Raw | ConvertFrom-Json).tools.ripgrep.linkedVia | Should -Be 'curated'
        Get-ChildItem (Split-Path $script:DestPath) -Filter '*.tmp.*' | Should -BeNullOrEmpty
    }

    It 'leaves no file behind on -WhatIf' {
        Mock Invoke-DFToolIdentityGuideDownload { New-FakeGuideDoc }
        Update-DFToolIdentityGuide -WhatIf
        Test-Path $script:DestPath | Should -BeFalse
    }

    It 'warns and writes nothing when the download fails' {
        Mock Invoke-DFToolIdentityGuideDownload { throw 'network down' }
        $w = $null
        Update-DFToolIdentityGuide -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'failed to download'
        Test-Path $script:DestPath | Should -BeFalse
    }

    It 'warns and leaves the existing copy untouched when validation fails' {
        New-DFDirectory (Split-Path $script:DestPath)
        'existing-good-content' | Set-Content $script:DestPath -NoNewline
        Mock Invoke-DFToolIdentityGuideDownload {
            # A tool entry missing both packages and linkedVia is what actually
            # fails Test-DFToolIdentityGuideSchema (an empty tools object alone
            # passes — there's no "must be non-empty" check at that level).
            [pscustomobject]@{ schemaVersion = 1; tools = [pscustomobject]@{ badtool = [pscustomobject]@{} } }
        }
        $w = $null
        Update-DFToolIdentityGuide -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'validation'
        Get-Content $script:DestPath -Raw | Should -Be 'existing-good-content'
    }

    It 'warns when XDG_DATA_HOME is unset' {
        $Env:XDG_DATA_HOME = $null
        Mock Invoke-DFToolIdentityGuideDownload { New-FakeGuideDoc }
        $w = $null
        Update-DFToolIdentityGuide -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'XDG_DATA_HOME'
    }
}
