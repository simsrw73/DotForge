BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $TestDrive 'tools'
    New-Item -ItemType Directory $script:Tools | Out-Null
    '{ "name": "pa", "executable": "pa.exe", "roles": { "pager": { "priority": 20, "env": { "DF_T2_PAGER": "pa" } } } }' | Set-Content (Join-Path $script:Tools 'pa.json')
    '{ "name": "pb", "executable": "pb.exe", "roles": { "pager": { "priority": 10, "env": { "DF_T2_PAGER": "pb" } } } }' | Set-Content (Join-Path $script:Tools 'pb.json')
    '{ "name": "rg", "executable": "rg.exe", "roles": { "grep": {} } }' | Set-Content (Join-Path $script:Tools 'rg.json')
}

Describe 'Get-DFRole' {
    BeforeEach {
        $script:DFToolDb = $null
        Set-DFTestConfig $null
        Remove-Item Env:DF_T2_PAGER -ErrorAction Ignore
        Mock Test-DFToolAvailable { $Executable -ne 'pb.exe' }
        # Point the role DB at a fixture whose pager reserves the test variable.
        $rolesFile = Join-Path $TestDrive 'roles.json'
        '{ "pager": { "kind": "single", "hook": "Initialize-DFRolePager", "reserved": { "env": ["DF_T2_PAGER"] } }, "grep": { "kind": "category" }, "prompt": { "kind": "single", "exclusive": true, "hook": "Initialize-DFRolePrompt" } }' | Set-Content $rolesFile
        $script:DFRoleDb = Get-DFRoleDb -Path $rolesFile
    }
    AfterEach {
        Remove-Item Env:DF_T2_PAGER -ErrorAction Ignore
        $script:DFRoleDb = $null
    }

    It 'reports members, installed candidates, winner and reason' {
        $r = Get-DFRole pager -ToolsPath $script:Tools
        $r.Kind | Should -Be 'single'
        $r.Members | Should -Be @('pa', 'pb')
        $r.Candidates | Should -Be @('pa')
        $r.Winner | Should -Be 'pa'
        $r.Reason | Should -Be 'sole'
    }

    It 'lists category roles with members and no winner' {
        $r = Get-DFRole grep -ToolsPath $script:Tools
        $r.Members | Should -Be @('rg')
        $r.Winner | Should -BeNullOrEmpty
    }

    It 'lists every role, sorted, when no name is given' {
        (Get-DFRole -ToolsPath $script:Tools).Name | Should -Be @('grep', 'pager', 'prompt')
    }

    It 'reports a reserved variable set outside DotForge as Overridden' {
        $Env:DF_T2_PAGER = 'less'
        $o = (Get-DFRole pager -ToolsPath $script:Tools).Overridden
        $o.Name | Should -Be 'DF_T2_PAGER'
        $o.Value | Should -Be 'less'
        $o.Source | Should -Be 'outside DotForge'
    }

    It 'reports nothing Overridden when the variable holds the winner''s value' {
        $Env:DF_T2_PAGER = 'pa'
        (Get-DFRole pager -ToolsPath $script:Tools).Overridden | Should -BeNullOrEmpty
    }

    It 'labels a value DotForge wrote for an earlier winner as such' {
        $global:DFRoleEnvState = @{ Written = @{ DF_T2_PAGER = 'pb' }; Warned = @{} }
        $Env:DF_T2_PAGER = 'pb'
        try {
            (Get-DFRole pager -ToolsPath $script:Tools).Overridden.Source | Should -Be 'DotForge (earlier winner)'
        } finally { Remove-Variable DFRoleEnvState -Scope Global -ErrorAction Ignore }
    }
}
