BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
    function script:New-ChainDb {
        $db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true } }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "packages": { "scoop": "fnm" }, "roles": { "version-manager": {} }, "installs": { "from": "fnm", "command": ["fnm","install","{id}"], "reactivate": true } }'),
            (Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts", "scoop": "nodejs-lts" }, "install": { "prefer": ["fnm"] }, "roles": { "js-runtime": {} } }'),
            (Rec '{ "name": "npm", "executable": "npm.cmd", "requires": ["node"], "roles": { "js-package-manager": { "priority": 30 } }, "installs": { "from": "npm", "command": ["npm","i","-g","{id}"], "batch": true } }'),
            (Rec '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow" } }')
        )) { $db[$r.name] = $r }
        $db
    }
    # Only scoop is installed on this "fresh machine".
    $script:OnlyScoop = { param($m) $m.name -eq 'scoop' }
}

Describe 'New-DFInstallPlan' {
    BeforeEach { Set-DFTestConfig $null; $script:Db = New-ChainDb }
    AfterEach { Set-DFTestConfig $null }

    It 'stages the scoop -> fnm -> node -> npm -> ish chain when all are requested' {
        $p = New-DFInstallPlan -Name fnm, node, npm, ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        ($p.Items | Where-Object Tool -eq fnm).Stage | Should -Be 1
        ($p.Items | Where-Object Tool -eq node).Stage | Should -Be 2
        ($p.Items | Where-Object Tool -eq node).Source | Should -Be 'fnm'
        ($p.Items | Where-Object Tool -eq npm).ProvidedBy | Should -Be 'node'
        ($p.Items | Where-Object Tool -eq npm).Stage | Should -Be 3
        ($p.Items | Where-Object Tool -eq ish).Stage | Should -Be 4
        $p.Gaps | Should -BeNullOrEmpty
    }
    It 'groups one stage''s tools into one batch per manager' {
        $p = New-DFInstallPlan -Name fnm, glow -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        $p.Stages.Count | Should -Be 1
        $p.Stages[0].Batches.Count | Should -Be 1
        $p.Stages[0].Batches[0].Manager.name | Should -Be 'scoop'
        @($p.Stages[0].Batches[0].Items.Tool) | Should -Be @('fnm', 'glow')
    }
    It 'never adds an unrequested manager: a gap names it and the tools that wait on it' {
        $p = New-DFInstallPlan -Name ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        $p.Items | Should -BeNullOrEmpty
        $p.Gaps[0].Tool | Should -Be 'ish'
        $p.Gaps[0].Options | Should -Be @('npm')
    }
    It 'adds a manager the user chose for a gap, with what it needs' {
        $p = New-DFInstallPlan -Name ish, fnm, node -ToolDb $script:Db -IsAvailable $script:OnlyScoop -Choice @{ npm = 'npm' }
        ($p.Items | Where-Object Tool -eq npm).ProvidedBy | Should -Be 'node'
        ($p.Items | Where-Object Tool -eq ish).DependsOn | Should -Contain 'npm'
    }
    It 'falls back past a preferred source whose manager is neither installed nor requested' {
        $p = New-DFInstallPlan -Name node, npm, ish -ToolDb $script:Db -IsAvailable $script:OnlyScoop
        # node prefers fnm, which isn't installed or requested, so scoop installs it; npm comes with it.
        ($p.Items | Where-Object Tool -eq node).Source | Should -Be 'scoop'
        $p.Gaps | Should -BeNullOrEmpty
    }
    It 'names the requested tools that wait on a gap' {
        $db = New-ChainDb
        $db.ishplug = Rec '{ "name": "ishplug", "executable": "ip.cmd", "requires": ["ish"], "packages": { "scoop": "ishplug" } }'
        $p = New-DFInstallPlan -Name ish, ishplug -ToolDb $db -IsAvailable $script:OnlyScoop
        ($p.Gaps | Where-Object Tool -eq ish).Dependents | Should -Contain 'ishplug'
        $p.Items.Tool | Should -Not -Contain 'ishplug'
    }
}
