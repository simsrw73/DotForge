BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFHelpTopicList.ps1"
}

Describe 'Get-DFHelpTopicList' {
    BeforeEach {
        $script:SavedXdg = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME = $TestDrive
    }
    AfterEach { $Env:XDG_CACHE_HOME = $script:SavedXdg }

    It 'returns topics as Name<TAB>Category lines' {
        Mock Get-Help {
            @(
                [PSCustomObject]@{ Name = 'Get-Process';    Category = 'Cmdlet'   },
                [PSCustomObject]@{ Name = 'about_Parsing';  Category = 'HelpFile' }
            )
        }
        Mock Get-Module { @() }
        $result = Get-DFHelpTopicList
        $result | Should -Contain "Get-Process`tCmdlet"
        $result | Should -Contain "about_Parsing`tHelpFile"
    }

    It 'writes help-topics.txt and help-topics.key on first run' {
        Mock Get-Help { @([PSCustomObject]@{ Name = 'Get-Item'; Category = 'Cmdlet' }) }
        Mock Get-Module { @() }
        Get-DFHelpTopicList
        Test-Path (Join-Path $TestDrive 'dotforge' 'help-topics.txt') | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'dotforge' 'help-topics.key') | Should -BeTrue
    }

    It 'returns cached list without calling Get-Help when fingerprint matches' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  ''              -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "Get-Item`tCmdlet" -Encoding UTF8
        Mock Get-Module { @() }
        Mock Get-Help { throw 'Should not be called on cache hit' }
        $result = Get-DFHelpTopicList
        $result | Should -Contain "Get-Item`tCmdlet"
    }

    It 'regenerates cache when fingerprint changes' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  'OldMod:1.0'     -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "OldTopic`tCmdlet" -Encoding UTF8
        Mock Get-Module {
            @([PSCustomObject]@{ Name = 'NewMod'; Version = [version]'2.0' })
        }
        Mock Get-Help { @([PSCustomObject]@{ Name = 'New-Topic'; Category = 'Cmdlet' }) }
        $result = Get-DFHelpTopicList
        $result | Should -Contain     "New-Topic`tCmdlet"
        $result | Should -Not -Contain "OldTopic`tCmdlet"
    }

    It '-Force regenerates cache even when fingerprint matches' {
        $cacheDir = Join-Path $TestDrive 'dotforge'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        Set-Content (Join-Path $cacheDir 'help-topics.key')  ''                 -Encoding UTF8
        Set-Content (Join-Path $cacheDir 'help-topics.txt') "OldTopic`tCmdlet"  -Encoding UTF8
        Mock Get-Module { @() }
        Mock Get-Help { @([PSCustomObject]@{ Name = 'Fresh-Topic'; Category = 'Cmdlet' }) }
        $result = Get-DFHelpTopicList -Force
        $result | Should -Contain     "Fresh-Topic`tCmdlet"
        $result | Should -Not -Contain "OldTopic`tCmdlet"
    }
}
