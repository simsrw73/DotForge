BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:ShippedTools = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
}

Describe 'The user tools folder' {
    BeforeEach {
        Set-DFTestXdg
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        # TestDrive lasts for the whole Describe: start each test with an empty folder.
        Remove-Item $script:UserTools -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Force -Path $script:UserTools | Out-Null
    }
    AfterEach {
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Restore-DFTestXdg
    }

    It 'is dotforge\tools under XDG_CONFIG_HOME' {
        Get-DFUserToolsPath | Should -Be (ConvertTo-DFPath $script:UserTools)
    }

    It 'adds a user record to the full load, next to the shipped ones' {
        '{ "name": "mytool", "executable": "mytool.exe" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        $db = Import-DFToolDb
        $db.ContainsKey('mytool') | Should -BeTrue
        $db.ContainsKey('bat') | Should -BeTrue
    }

    It 'lets a user record replace the shipped record of the same name, whole' {
        '{ "name": "bat", "executable": "mybat.exe" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        $bat = (Import-DFToolDb)['bat']
        $bat.executable | Should -Be 'mybat.exe'
        $bat.aliases | Should -BeNullOrEmpty
    }

    It 'prefers the user record when loading by name' {
        '{ "name": "bat", "executable": "mybat.exe" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        '{ "name": "mytool", "executable": "mytool.exe" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        $db = Import-DFToolDb -Name bat, mytool, fd
        $db.bat.executable | Should -Be 'mybat.exe'
        $db.mytool | Should -Not -BeNullOrEmpty
        $db.fd.source | Should -Be 'builtin'
    }

    It 'marks where each record came from' {
        '{ "name": "mytool", "executable": "mytool.exe" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        $db = Import-DFToolDb
        $db.mytool.source | Should -Be 'user'
        $db.mytool.folder | Should -Be (ConvertTo-DFPath $script:UserTools)
        $db.bat.source | Should -Be 'builtin'
        $db.bat.folder | Should -Be $script:ShippedTools
    }

    It 'keeps the shipped record when the user record of that name is invalid' {
        '{ "name": "bat" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        $db = Import-DFToolDb 3>$null
        $db.bat.source | Should -Be 'builtin'
        (Import-DFToolDb -Name bat -Force 3>$null).bat.source | Should -Be 'builtin'
    }

    It 'skips, with a warning, a user record whose name differs from its file name' {
        '{ "name": "fzf", "executable": "x.exe" }' | Set-Content (Join-Path $script:UserTools 'mine.json')
        $db = Import-DFToolDb -WarningVariable warnings 3>$null
        "$warnings" | Should -Match "mine\.json.*'fzf'"
        $db.fzf.source | Should -Be 'builtin'
        $db.ContainsKey('mine') | Should -BeFalse
        $byName = Import-DFToolDb -Name mine -Force 3>$null
        $byName.Count | Should -Be 0
        $script:DFToolRecordCache.ContainsKey('fzf') | Should -BeFalse
    }

    It 'never changes the shared registry record when a user copy matches a shipped file' {
        Copy-Item (Join-Path $script:ShippedTools 'bat.json') $script:UserTools
        $bat = (Import-DFToolDb -Name bat)['bat']
        $bat.source | Should -Be 'user'
        (Get-DFToolRegistry)['bat'].record.PSObject.Properties['source']?.Value | Should -Not -Be 'user'
        (Get-DFToolRegistry)['bat'].record.PSObject.Properties['folder']?.Value | Should -BeNullOrEmpty
    }

    It 'ignores the user folder when -ToolsPath is given' {
        '{ "name": "mytool", "executable": "mytool.exe" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        (Import-DFToolDb -ToolsPath $script:ShippedTools).ContainsKey('mytool') | Should -BeFalse
        Get-DFToolNames -ToolsPath $script:ShippedTools | Should -Not -Contain 'mytool'
    }

    It 'lists user tool names with the shipped ones, once each' {
        '{ "name": "mytool", "executable": "mytool.exe" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        '{ "name": "bat", "executable": "mybat.exe" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        $names = Get-DFToolNames
        $names | Should -Contain 'mytool'
        @($names | Where-Object { $_ -eq 'bat' }).Count | Should -Be 1
    }

    It 'works when the user folder does not exist' {
        Remove-Item $script:UserTools -Recurse -Force
        (Import-DFToolDb).ContainsKey('bat') | Should -BeTrue
        (Import-DFToolDb -Name bat -Force).bat | Should -Not -BeNullOrEmpty
    }
}
