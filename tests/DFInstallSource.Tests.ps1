BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
    function script:New-Db {
        $db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'),
            (Rec '{ "name": "winget", "executable": "winget.exe", "roles": { "package-manager": { "priority": 20 } }, "installs": { "from": "winget", "command": ["winget","install","{id}"] } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "roles": { "package-manager": { "priority": 10 } }, "installs": { "from": "choco", "command": ["choco","install","{id}"], "elevate": true } }'),
            (Rec '{ "name": "npm", "executable": "npm.cmd", "roles": { "js-package-manager": { "priority": 30 } }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"] } }'),
            (Rec '{ "name": "pnpm", "executable": "pnpm.cmd", "roles": { "js-package-manager": { "priority": 20 } }, "installs": { "from": "npm", "command": ["pnpm","add","-g","{id}"] } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow", "winget": "charm.glow", "choco": "glow" }, "install": { "prefer": ["winget"] } }'),
            (Rec '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }')
        )) { $db[$r.name] = $r }
        $db
    }
    $script:All = { param($r) $true }
}

Describe 'Get-DFInstallSourceOrder' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }

    It 'puts the tool spec''s preference first, then the built-in order' {
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('winget', 'scoop', 'choco')
    }
    It 'lets InstallOrder reorder what the tool spec didn''t pin' {
        Set-DFTestConfig @{ InstallOrder = @('choco', 'scoop') }
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('winget', 'choco', 'scoop')
    }
    It 'puts InstallVia above everything' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db)[0] | Should -Be 'choco'
    }
    It 'puts a per-call -Via above the InstallVia setting' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db -Via @{ glow = 'scoop' })[0] | Should -Be 'scoop'
    }
    It 'drops excluded sources, unless InstallVia names one' {
        Set-DFTestConfig @{ ExcludeSources = @('choco') }
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Not -Contain 'choco'
        Set-DFTestConfig @{ ExcludeSources = @('choco'); InstallVia = @{ glow = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db)[0] | Should -Be 'choco'
    }
    It 'warns about an InstallVia source the tool has no package for, and ignores it' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'crates' } }
        $o = Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db -WarningVariable w 3>$null
        $o[0] | Should -Be 'winget'
        "$w" | Should -Match "InstallVia.*glow.*crates"
    }
}

Describe 'Get-DFSourceManager' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }
    It 'ranks a registry''s managers by priority, and Defaults first' {
        (Get-DFSourceManager -Source npm -ToolDb $script:Db).name | Should -Be @('npm', 'pnpm')
        Set-DFTestConfig @{ Defaults = @{ 'js-package-manager' = 'pnpm' } }
        (Get-DFSourceManager -Source npm -ToolDb $script:Db).name | Should -Be @('pnpm', 'npm')
    }
}

Describe 'Resolve-DFInstallSource' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-Db }
    AfterEach { Set-DFTestConfig $null }

    It 'takes the first source whose manager is available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.glow -ToolDb $script:Db -IsAvailable { param($m) $m.name -ne 'winget' }
        $r.Source | Should -Be 'scoop'
        $r.Manager.name | Should -Be 'scoop'
        $r.Ref.Id | Should -Be 'glow'
        $r.Gap | Should -BeNullOrEmpty
    }
    It 'counts a manager planned in an earlier stage as available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false } -Planned @('npm')
        $r.Manager.name | Should -Be 'npm'
    }
    It 'reports a gap, with the managers that could serve it, when nothing is available' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false }
        $r.Gap | Should -Match 'npm'
        $r.Options | Should -Be @('npm', 'pnpm')
    }
    It 'uses the user''s choice for a gap source' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ish -ToolDb $script:Db -IsAvailable { param($m) $false } -Choice @{ npm = 'pnpm' }
        $r.Manager.name | Should -Be 'pnpm'
        $r.Gap | Should -BeNullOrEmpty
    }
    It 'names the exclusion when it leaves no source' {
        $db = New-Db
        $db.only = Rec '{ "name": "only", "executable": "o.exe", "packages": { "choco": "only" } }'
        Set-DFTestConfig @{ ExcludeSources = @('choco') }
        (Resolve-DFInstallSource -Tool $db.only -ToolDb $db -IsAvailable $script:All).Gap |
            Should -Match 'no source left.*choco.*ExcludeSources'
    }
    It 'reports a tool with no packages at all' {
        $db = New-Db
        $db.bare = Rec '{ "name": "bare", "executable": "b.exe" }'
        (Resolve-DFInstallSource -Tool $db.bare -ToolDb $db -IsAvailable $script:All).Gap | Should -Match 'no package'
    }
}
