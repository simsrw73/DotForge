BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Find-DFToolSource' {
    BeforeEach {
        $script:Db = @{
            scoop  = Rec '{ "name": "scoop", "executable": "scoop.cmd", "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "list": "Get-FakeScoopInstalled", "feeds": { "list": ["x"], "add": ["y"], "id": "{feed}/{id}" } } }'
            winget = Rec '{ "name": "winget", "executable": "winget.exe", "installs": { "from": "winget", "install": ["winget","install","{id}"], "list": "Get-FakeWingetInstalled" } }'
            rg     = Rec '{ "name": "rg", "executable": "rg.exe", "packages": { "scoop": "ripgrep", "winget": "BurntSushi.ripgrep.MSVC" } }'
        }
        $script:Tool = $script:Db.rg
        Mock Import-DFManagerOps { }
        Mock Test-DFToolAvailable { $true }
        Set-DFTestConfig @{ InstallOrder = @('scoop', 'winget') }
        function script:Get-FakeScoopInstalled { param($Manager) [pscustomobject]@{ Id = 'ripgrep'; Installed = '14.1.0'; Available = $null } }
        function script:Get-FakeWingetInstalled { param($Manager) throw 'should not be asked' }
    }
    AfterEach { Set-DFTestConfig $null }

    It 'asks the first manager in precedence order and stops at a match' {
        $r = Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db
        $r.Tool | Should -Be 'rg'
        $r.Manager.name | Should -Be 'scoop'
        $r.Source | Should -Be 'scoop'
        $r.Id | Should -Be 'ripgrep'
        $r.Installed | Should -Be '14.1.0'
        $r.Block.from | Should -Be 'scoop'
    }
    It 'moves on when the first manager does not have it' {
        function script:Get-FakeScoopInstalled { param($Manager) }
        function script:Get-FakeWingetInstalled { param($Manager) [pscustomobject]@{ Id = 'BurntSushi.ripgrep.MSVC'; Installed = '14.0'; Available = $null } }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager.name | Should -Be 'winget'
    }
    It 'matches ids without regard to case' {
        function script:Get-FakeScoopInstalled { param($Manager) [pscustomobject]@{ Id = 'RipGrep'; Installed = '1'; Available = $null } }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager.name | Should -Be 'scoop'
    }
    It 'treats a list function that throws as not having it' {
        function script:Get-FakeScoopInstalled { param($Manager) throw 'boom' }
        function script:Get-FakeWingetInstalled { param($Manager) }
        $r = Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db
        $r.Manager | Should -BeNullOrEmpty
        $r.Detail | Should -Be 'not installed through any of: scoop, winget'
    }
    It 'ignores rows of the wrong shape' {
        function script:Get-FakeScoopInstalled { param($Manager) 'ripgrep 14.1.0'; [pscustomobject]@{ Name = 'ripgrep' } }
        function script:Get-FakeWingetInstalled { param($Manager) }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager | Should -BeNullOrEmpty
    }
    It 'skips a manager that is not installed' {
        Mock Test-DFToolAvailable { $false } -ParameterFilter { $Executable -eq 'scoop.cmd' }
        function script:Get-FakeScoopInstalled { param($Manager) throw 'should not be asked' }
        function script:Get-FakeWingetInstalled { param($Manager) [pscustomobject]@{ Id = 'BurntSushi.ripgrep.MSVC'; Installed = '14.0'; Available = $null } }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager.name | Should -Be 'winget'
    }
    It 'says when no manager for its sources is installed' {
        Mock Test-DFToolAvailable { $false }
        $r = Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db
        $r.Manager | Should -BeNullOrEmpty
        $r.Detail | Should -Be 'no manager for scoop, winget is installed'
    }
    It 'still finds a tool installed through a source IncludeSources leaves out' {
        Set-DFTestConfig @{ IncludeSources = @('scoop') }
        function script:Get-FakeScoopInstalled { param($Manager) }
        function script:Get-FakeWingetInstalled { param($Manager) [pscustomobject]@{ Id = 'BurntSushi.ripgrep.MSVC'; Installed = '14.0'; Available = $null } }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager.name | Should -Be 'winget'
    }
    It 'still finds a tool installed through an excluded source, asking it last' {
        Set-DFTestConfig @{ InstallOrder = @('scoop', 'winget'); ExcludeSources = @('scoop') }
        function script:Get-FakeWingetInstalled { param($Manager) }
        (Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db).Manager.name | Should -Be 'scoop'
    }
    It 'matches a package from a feed by its feed-qualified id' {
        $tool = Rec '{ "name": "dotenv", "executable": "dotenv", "packages": { "scoop": { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://u" } } } }'
        function script:Get-FakeScoopInstalled { param($Manager) [pscustomobject]@{ Id = 'insomnia/ps-dotenv'; Installed = '1'; Available = $null } }
        (Find-DFToolSource -Tool $tool -ToolDb $script:Db).Id | Should -Be 'insomnia/ps-dotenv'
    }
    It 'attributes an installed runtime to a version manager that cannot list, when no listing manager has it' {
        $script:Db.fnm = Rec '{ "name": "fnm", "executable": "fnm.exe", "installs": { "from": "fnm", "install": ["fnm","install","{id}"] } }'
        $node = Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts", "scoop": "nodejs-lts" } }'
        Set-DFTestConfig @{ InstallOrder = @('fnm', 'scoop') }
        function script:Get-FakeScoopInstalled { param($Manager) }
        $r = Find-DFToolSource -Tool $node -ToolDb $script:Db
        $r.Manager.name | Should -Be 'fnm'
        $r.Source | Should -Be 'fnm'
        $r.Detail | Should -Be "via fnm (it can't list what it installed)"
    }
    It 'prefers a listing manager that has the runtime' {
        $script:Db.fnm = Rec '{ "name": "fnm", "executable": "fnm.exe", "installs": { "from": "fnm", "install": ["fnm","install","{id}"] } }'
        $node = Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts", "scoop": "nodejs-lts" } }'
        Set-DFTestConfig @{ InstallOrder = @('fnm', 'scoop') }
        function script:Get-FakeScoopInstalled { param($Manager) [pscustomobject]@{ Id = 'nodejs-lts'; Installed = '22'; Available = $null } }
        (Find-DFToolSource -Tool $node -ToolDb $script:Db).Manager.name | Should -Be 'scoop'
    }
    It 'does not attribute a runtime that is not installed' {
        $script:Db.fnm = Rec '{ "name": "fnm", "executable": "fnm.exe", "installs": { "from": "fnm", "install": ["fnm","install","{id}"] } }'
        $node = Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts" } }'
        Mock Test-DFToolAvailable { $false } -ParameterFilter { $Executable -eq 'node.exe' }
        (Find-DFToolSource -Tool $node -ToolDb $script:Db).Manager | Should -BeNullOrEmpty
    }
    It 'says when a tool lists no packages' {
        $tool = Rec '{ "name": "npm", "executable": "npm.cmd" }'
        (Find-DFToolSource -Tool $tool -ToolDb $script:Db).Detail | Should -Be 'its record lists no packages'
    }
    It 'asks a manager once per command run, however many tools' {
        $cache = @{}
        Mock Get-FakeScoopInstalled { [pscustomobject]@{ Id = 'ripgrep'; Installed = '1'; Available = $null } }
        $null = Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db -Cache $cache
        $null = Find-DFToolSource -Tool $script:Tool -ToolDb $script:Db -Cache $cache
        Should -Invoke Get-FakeScoopInstalled -Times 1 -Exactly
    }
}

Describe 'Get-DFManagerInstalled' {
    It 'is empty for a manager without a list function' {
        $m = Rec '{ "name": "m", "executable": "m", "installs": { "from": "m", "install": ["m"] } }'
        @(Get-DFManagerInstalled -Manager $m -Block $m.installs[0]) | Should -HaveCount 0
    }
    It 'passes the manager record to the list function' {
        function script:Get-FakeListed { param($Manager) [pscustomobject]@{ Id = $Manager.name; Installed = '1'; Available = $null } }
        $m = Rec '{ "name": "m", "executable": "m", "installs": { "from": "m", "install": ["m"], "list": "Get-FakeListed" } }'
        (Get-DFManagerInstalled -Manager $m -Block $m.installs[0]).Id | Should -Be 'm'
    }
}

Describe 'Import-DFManagerOps' {
    It 'loads the manager''s .manage.ps1 so its functions can be called, once' {
        $dir = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory $dir -Force | Out-Null
        'function Get-DFFakeOpsInstalled { param($Manager) "loaded" }' | Set-Content (Join-Path $dir 'fakeops.manage.ps1')
        Import-DFManagerOps -Manager ([pscustomobject]@{ name = 'fakeops' }) -ToolsPath $dir
        Get-DFFakeOpsInstalled | Should -Be 'loaded'
    }
    It 'does nothing for a manager without a manage file' {
        { Import-DFManagerOps -Manager ([pscustomobject]@{ name = 'nomanage' }) -ToolsPath $TestDrive } | Should -Not -Throw
    }
}
