BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:ShippedTools = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
}

# A user record's companion, setup script, seeds and manage functions come from
# the folder its JSON was read from, never from the shipped Tools folder.
Describe 'Files of a user tool record' {
    BeforeEach {
        Set-DFTestXdg
        Reset-DFTestSession
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        Remove-Item $script:UserTools -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Force -Path $script:UserTools | Out-Null
        $global:DFTestUserCompanion = $null
    }
    AfterEach {
        $script:DFToolDb = $null
        $script:DFToolRecordCache = @{}
        Remove-Variable -Name DFTestUserCompanion -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function Get-DFTestUserThing
        Restore-DFTestXdg
    }

    It 'runs the companion next to the user record' {
        '{ "name": "mytool", "executable": "Pester", "type": "module" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        '$global:DFTestUserCompanion = $PSScriptRoot' | Set-Content (Join-Path $script:UserTools 'mytool.ps1')
        $tool = (Import-DFToolDb -Name mytool).mytool
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:ShippedTools
        $global:DFTestUserCompanion | Should -Be (ConvertTo-DFPath $script:UserTools)
    }

    It 'runs the user companion, not the shipped one, for an overridden tool' {
        '{ "name": "bat", "executable": "Pester", "type": "module" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        '$global:DFTestUserCompanion = "user"' | Set-Content (Join-Path $script:UserTools 'bat.ps1')
        $tool = (Import-DFToolDb -Name bat).bat
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:ShippedTools
        $global:DFTestUserCompanion | Should -Be 'user'
    }

    It 'runs the setup script next to the user record' {
        '{ "name": "mytool", "executable": "Pester", "type": "module" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        '$global:DFTestUserCompanion = "setup"; Complete-DFToolSetup -Name mytool' | Set-Content (Join-Path $script:UserTools 'mytool.setup.ps1')
        $tool = (Import-DFToolDb -Name mytool).mytool
        Invoke-DFToolCompanion -Tool $tool -ToolsPath $script:ShippedTools -SetupOnly
        $global:DFTestUserCompanion | Should -Be 'setup'
    }

    It 'seeds from the user record''s folder' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:UserTools 'mytool') | Out-Null
        'seeded' | Set-Content (Join-Path $script:UserTools 'mytool' 'config')
        '{ "name": "mytool", "executable": "Pester", "type": "module", "setup": { "seed": { "${XDG_CONFIG_HOME}/mytool/config": "mytool/config" } } }' |
            Set-Content (Join-Path $script:UserTools 'mytool.json')
        $tool = (Import-DFToolDb -Name mytool).mytool
        $null = Invoke-DFToolSeed -Tool $tool -ToolsPath $script:ShippedTools
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'mytool' 'config') | Should -Be 'seeded'
    }

    It 'loads a user package manager''s manage functions from its folder' {
        '{ "name": "mypm", "executable": "Pester", "type": "module" }' | Set-Content (Join-Path $script:UserTools 'mypm.json')
        'function Get-DFTestUserThing { ''from user'' }' | Set-Content (Join-Path $script:UserTools 'mypm.manage.ps1')
        $manager = (Import-DFToolDb -Name mypm).mypm
        Import-DFManagerOps -Manager $manager -ToolsPath $script:ShippedTools
        Get-DFTestUserThing | Should -Be 'from user'
    }

    It 'picks up a user copy made after the shipped record was loaded, on Register-DFTool' {
        $null = Import-DFToolDb -Name bat
        $null = Import-DFToolDb
        '{ "name": "bat", "executable": "Pester", "type": "module" }' | Set-Content (Join-Path $script:UserTools 'bat.json')
        '$global:DFTestUserCompanion = "user"' | Set-Content (Join-Path $script:UserTools 'bat.ps1')
        Register-DFTool -Name bat
        $global:DFTestUserCompanion | Should -Be 'user'
        (Import-DFToolDb)['bat'].source | Should -Be 'user'
    }

    It 're-reads an edited user record on Register-DFTool' {
        '{ "name": "mytool", "executable": "Pester", "type": "module", "description": "old" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        Register-DFTool -Name mytool
        '{ "name": "mytool", "executable": "Pester", "type": "module", "description": "new" }' | Set-Content (Join-Path $script:UserTools 'mytool.json')
        Register-DFTool -Name mytool
        (Import-DFToolDb -Name mytool).mytool.description | Should -Be 'new'
    }

    It 'registers a user tool end to end, with its companion' {
        '{ "name": "mytool", "executable": "Pester", "type": "module", "aliases": { "mt": { "command": "Get-Date" } } }' |
            Set-Content (Join-Path $script:UserTools 'mytool.json')
        '$global:DFTestUserCompanion = "ran"' | Set-Content (Join-Path $script:UserTools 'mytool.ps1')
        Register-DFTool -Name mytool
        $global:DFTestUserCompanion | Should -Be 'ran'
        (Get-DFToolStatus -Name mytool).State | Should -Be 'Active'
        Remove-DFTestGlobal -Alias mt
    }
}
