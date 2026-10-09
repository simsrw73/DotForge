BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Shipped = Get-Content "$PSScriptRoot/../data/groups.json" -Raw | ConvertFrom-Json -AsHashtable
    $script:ToolNames = (Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            (Get-Content $_.FullName -Raw | ConvertFrom-Json).name })
}

Describe 'data/groups.json' {
    It 'has at least one group' {
        $script:Shipped.Count | Should -BeGreaterThan 0
    }
    It 'uses lowercase names of letters, digits and hyphens' {
        @($script:Shipped.Keys | Where-Object { $_ -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' }) | Should -BeNullOrEmpty
    }
    It 'gives every group a description and a non-empty tool list' {
        foreach ($g in $script:Shipped.GetEnumerator()) {
            $g.Value.description | Should -Not -BeNullOrEmpty -Because $g.Key
            @($g.Value.tools).Count | Should -BeGreaterThan 0 -Because $g.Key
        }
    }
    It 'names only tools that exist in Tools/ (exact case)' {
        $unknown = foreach ($g in $script:Shipped.GetEnumerator()) {
            foreach ($t in $g.Value.tools) { if ($t -cnotin $script:ToolNames) { "$($g.Key): $t" } }
        }
        @($unknown) | Should -BeNullOrEmpty
    }
    It 'does not nest groups (no member starts with +)' {
        @($script:Shipped.Values.tools | Where-Object { $_ -like '+*' }) | Should -BeNullOrEmpty
    }
    It 'never uses a tool name as a group name' {
        @($script:Shipped.Keys | Where-Object { $_ -in $script:ToolNames }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFGroupDb' {
    BeforeEach { $script:DFGroupDb = $null }

    It 'loads the shipped groups, keyed case-insensitively' {
        $db = Get-DFGroupDb
        $db.Contains('CORE') | Should -BeTrue
        @($db['core'].Tools).Count | Should -BeGreaterThan 0
    }
    It 'loads a custom file when -Path is given, without caching it' {
        $p = Join-Path $TestDrive 'groups.json'
        '{ "mine": { "description": "d", "tools": ["bat"] } }' | Set-Content $p
        (Get-DFGroupDb -Path $p).Keys | Should -Be @('mine')
        (Get-DFGroupDb).Contains('mine') | Should -BeFalse
    }
}

Describe 'Get-DFToolGroup' {
    BeforeEach { $script:DFGroupDb = $null }

    It 'lists every group with its description and tools' {
        $all = @(Get-DFToolGroup)
        $all.Count | Should -Be $script:Shipped.Count
        $all[0].PSObject.TypeNames[0] | Should -Be 'DotForge.ToolGroup'
        ($all | Where-Object Name -eq 'core').Tools | Should -Contain 'bat'
    }
    It 'accepts a name with or without the + prefix' {
        (Get-DFToolGroup -Name '+core').Name | Should -Be 'core'
        (Get-DFToolGroup -Name 'core').Name | Should -Be 'core'
    }
    It 'warns about an unknown group' {
        Get-DFToolGroup -Name '+nope' -WarningVariable w 3>$null | Should -BeNullOrEmpty
        "$w" | Should -Match 'nope'
    }
}
