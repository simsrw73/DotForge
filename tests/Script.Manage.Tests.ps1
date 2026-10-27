BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    . "$PSScriptRoot/../Tools/script.manage.ps1"
}

# The script-installer source (T-84): a tool's packages.script entry names the installer URL, where
# the installed program is, how it updates and what removing it deletes
# (docs/superpowers/specs/2026-10-27-claude-code-design.md). No test downloads or runs anything.
Describe 'script manager operations' {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        New-Item -ItemType Directory -Force $script:UserTools | Out-Null
        $script:Url = 'https://example.invalid/scripty/install.ps1'
        $script:Home2 = Join-Path $Env:XDG_DATA_HOME 'scripty'
        $script:Program = Join-Path $script:Home2 'scripty.exe'
        @{ name = 'scripty'; executable = 'scripty.exe'
           packages = @{ script = @{ id = $script:Url; installed = '${XDG_DATA_HOME}/scripty/scripty.exe'
                                    update = @('scripty', 'update'); remove = @('${XDG_DATA_HOME}/scripty') } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'scripty.json')
        $script:Ran = $null
        Mock Invoke-DFScriptDownload { "'installed'" }
        Mock Invoke-DFScriptProcess { $script:Ran = $Path; Test-Path -LiteralPath $Path | Should -BeTrue; 0 }
        Mock Write-Host { }
    }
    AfterEach {
        Remove-Item $script:Home2 -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'installs by downloading the record''s script, running it, then deleting it' {
        Install-DFScriptPackage -Id $script:Url -Confirm:$false
        Should -Invoke Invoke-DFScriptDownload -Times 1 -Exactly -ParameterFilter { $Url -eq $script:Url }
        Should -Invoke Invoke-DFScriptProcess -Times 1 -Exactly
        Test-Path -LiteralPath $script:Ran | Should -BeFalse
    }
    It 'refuses a non-https URL without downloading' {
        $http = 'http://example.invalid/scripty/install.ps1'
        @{ name = 'scripty'; executable = 'scripty.exe'; packages = @{ script = @{ id = $http; installed = '${XDG_DATA_HOME}/scripty/scripty.exe' } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'scripty.json')
        { Install-DFScriptPackage -Id $http -Confirm:$false } | Should -Throw '*https*'
        Should -Invoke Invoke-DFScriptDownload -Times 0 -Exactly
    }
    It 'refuses a URL no tool record names' {
        { Install-DFScriptPackage -Id 'https://example.invalid/other.ps1' -Confirm:$false } | Should -Throw '*no tool record*'
        Should -Invoke Invoke-DFScriptDownload -Times 0 -Exactly
    }
    It 'runs nothing with -WhatIf, and doesn''t ask with -Confirm:$false' {
        Install-DFScriptPackage -Id $script:Url -WhatIf
        Should -Invoke Invoke-DFScriptDownload -Times 0 -Exactly
        $ConfirmPreference = 'High'
        Install-DFScriptPackage -Id $script:Url -Confirm:$false
        Should -Invoke Invoke-DFScriptProcess -Times 1 -Exactly
    }
    It 'throws when the script exits non-zero' {
        Mock Invoke-DFScriptProcess { 3 }
        { Install-DFScriptPackage -Id $script:Url -Confirm:$false } | Should -Throw '*3*'
    }
    It 'lists a tool whose installed path exists' {
        @(Get-DFScriptInstalled -Manager ([pscustomobject]@{ name = 'script' })) | Where-Object Id -eq $script:Url | Should -BeNullOrEmpty
        New-Item -ItemType File -Force $script:Program | Out-Null
        $row = @(Get-DFScriptInstalled -Manager ([pscustomobject]@{ name = 'script' })) | Where-Object Id -eq $script:Url
        $row.Installed | Should -Be 'installed'
    }
    It 'removes exactly the declared paths' {
        New-Item -ItemType File -Force $script:Program | Out-Null
        $keep = Join-Path $Env:XDG_DATA_HOME 'keep.txt'
        New-Item -ItemType File -Force $keep | Out-Null
        Remove-DFScriptPackage -Id $script:Url -Confirm:$false
        Test-Path $script:Home2 | Should -BeFalse
        Test-Path $keep | Should -BeTrue
    }
    It 'refuses a declared path that a link inside the home folder sends outside it, deleting nothing' {
        # M1: the check follows links, not just the text of the path.
        $fakeHome = Join-Path $TestDrive 'fakehome'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Force $fakeHome, (Join-Path $outside 'scripty') | Out-Null
        New-Item -ItemType File -Force (Join-Path $outside 'scripty' 'keep.txt') | Out-Null
        $null = New-Item -ItemType Junction -Path (Join-Path $fakeHome 'data') -Target $outside
        try {
            Mock Get-DFScriptHome { ConvertTo-DFPath $fakeHome }
            @{ name = 'scripty'; executable = 'scripty.exe'
               packages = @{ script = @{ id = $script:Url; installed = '${HOME}/data/scripty/scripty.exe'; remove = @('${HOME}/data/scripty') } } } |
                ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'scripty.json')
            { Remove-DFScriptPackage -Id $script:Url -Confirm:$false } | Should -Throw '*outside*'
            Test-Path (Join-Path $outside 'scripty' 'keep.txt') | Should -BeTrue
        } finally { [IO.Directory]::Delete((Join-Path $fakeHome 'data')) }
    }
    It 'says you declined, instead of reporting an install, when you answer no' {
        # M3
        Mock Test-DFScriptConsent { $false }
        { Install-DFScriptPackage -Id $script:Url } | Should -Throw '*declined*'
        Should -Invoke Invoke-DFScriptDownload -Times 0 -Exactly
    }
    It 'removes without asking again for each path (Remove-DFTool already asked)' {
        New-Item -ItemType File -Force $script:Program | Out-Null
        $ConfirmPreference = 'High'
        Remove-DFScriptPackage -Id $script:Url
        Test-Path $script:Home2 | Should -BeFalse
    }
    It 'refuses a path outside the home folder, deleting nothing' {
        # The schema already rejects a record whose remove path climbs out with '..'; this checks the
        # removal's own guard, should such an entry reach it.
        New-Item -ItemType File -Force $script:Program | Out-Null
        $deep = '${XDG_DATA_HOME}' + ('/..' * 12) + '/dfx-outside'
        Mock Find-DFScriptPackage { [pscustomobject]@{ Tool = [pscustomobject]@{ name = 'scripty' }; Entry = [pscustomobject]@{ id = $script:Url; remove = @('${XDG_DATA_HOME}/scripty', $deep) } } }
        { Remove-DFScriptPackage -Id $script:Url -Confirm:$false } | Should -Throw '*outside*'
        Test-Path $script:Program | Should -BeTrue
    }
    It 'updates with the declared command' {
        Mock Invoke-DFManagerCommand { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Update-DFScriptPackage -Id $script:Url
        Should -Invoke Invoke-DFManagerCommand -Times 1 -Exactly -ParameterFilter { $Operation -eq 'update' -and ($Argv -join ' ') -eq 'scripty update' }
    }
    It 'says a self-updating tool updates itself' {
        @{ name = 'scripty'; executable = 'scripty.exe'; packages = @{ script = @{ id = $script:Url; installed = '${XDG_DATA_HOME}/scripty/scripty.exe'; update = 'self' } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:UserTools 'scripty.json')
        Mock Invoke-DFManagerCommand { }
        $result = Update-DFScriptPackage -Id $script:Url
        $result.DFSkipped | Should -Match 'updates itself'
        Should -Invoke Invoke-DFManagerCommand -Times 0 -Exactly
    }
}
