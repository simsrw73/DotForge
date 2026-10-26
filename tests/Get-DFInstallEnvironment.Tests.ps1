BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Get-DFInstallEnvironment' {
    BeforeEach {
        Set-DFTestXdg
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd" }'),
            (Rec '{ "name": "rustup", "executable": "rustup.exe", "xdg": { "method": "env", "vars": { "RUSTUP_HOME": "${XDG_DATA_HOME}/rustup", "CARGO_HOME": "${XDG_DATA_HOME}/cargo" } } }'),
            (Rec '{ "name": "cargo", "executable": "cargo.exe", "requires": ["rustup"] }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "xdg": { "method": "env", "vars": { "FNM_DIR": "${XDG_DATA_HOME}/fnm" } } }'),
            (Rec '{ "name": "bat", "executable": "bat.exe", "xdg": { "method": "env", "vars": { "BAT_CONFIG_DIR": "${XDG_CONFIG_HOME}/bat" } }, "env": { "BAT_THEME": "x" } }'),
            (Rec '{ "name": "wrapped", "executable": "w.exe", "xdg": { "method": "wrapper", "vars": { "W": "${XDG_CONFIG_HOME}/w" } } }'),
            (Rec '{ "name": "pipx", "executable": "pipx.exe", "requires": ["role:python-runtime"] }'),
            (Rec '{ "name": "ghost", "executable": "ghost.exe", "requires": ["nothere"] }'),
            (Rec '{ "name": "a", "executable": "a.exe", "requires": ["b"], "xdg": { "method": "env", "vars": { "A_HOME": "${XDG_DATA_HOME}/a" } } }'),
            (Rec '{ "name": "b", "executable": "b.exe", "requires": ["a"], "xdg": { "method": "env", "vars": { "B_HOME": "${XDG_DATA_HOME}/b" } } }'),
            (Rec '{ "name": "t1", "executable": "t1.exe", "xdg": { "method": "env", "vars": { "FNM_DIR": "${XDG_CACHE_HOME}/x" } } }')
        )) { $script:Db[$r.name] = $r }
        # Only tools this session requested count: every one is Active unless a test says otherwise.
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $script:Db.Keys) { $script:DFSessionStatus[$name] = New-DFToolStatus -Name $name -State Active -RequestedBy 'Tools' }
        $script:Env = { param($Tool, $Manager) Get-DFInstallEnvironment -Tool @($Tool | ForEach-Object { $script:Db[$_] }) -Manager $script:Db[$Manager] -ToolDb $script:Db }
    }
    AfterEach { Restore-DFTestXdg; $script:DFSessionStatus = $null }

    It "returns the tool's own variables" {
        $e = & $script:Env 'bat' 'scoop'
        @($e.Keys) | Should -Be @('BAT_CONFIG_DIR')
        $e['BAT_CONFIG_DIR'] | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'bat'))
    }
    It "adds the manager's variables" {
        @((& $script:Env @() 'fnm').Keys) | Should -Be @('FNM_DIR')
    }
    It "follows the manager's requires chain" {
        $keys = @((& $script:Env @() 'cargo').Keys)
        $keys | Should -Contain 'RUSTUP_HOME'
        $keys | Should -Contain 'CARGO_HOME'
    }
    It "doesn't follow a role requirement" {
        (& $script:Env @() 'pipx').Count | Should -Be 0
    }
    It 'skips a required tool with no record' {
        (& $script:Env @() 'ghost').Count | Should -Be 0
    }
    It 'stops on a requires cycle' {
        @((& $script:Env @() 'a').Keys) | Should -Be @('A_HOME', 'B_HOME')
    }
    It 'leaves out a variable whose location is linked to existing data' {
        try {
            Set-DFToolLinkState -Name bat -Links @([pscustomobject]@{ key = 'BAT_CONFIG_DIR'; path = 'C:\x'; target = 'C:\y'; made = $true })
            (& $script:Env 'bat' 'scoop').Count | Should -Be 0
        } finally { Set-DFToolLinkState -Name bat }
    }
    It 'ignores the env map and non-env methods' {
        @((& $script:Env @('bat', 'wrapped') 'scoop').Keys) | Should -Be @('BAT_CONFIG_DIR')
    }
    It 'includes a requested tool that is not installed yet' {
        $script:DFSessionStatus['bat'] = New-DFToolStatus -Name bat -State Missing -RequestedBy 'Tools'
        @((& $script:Env 'bat' 'scoop').Keys) | Should -Be @('BAT_CONFIG_DIR')
    }
    It "skips a tool in Conflict: its data stays where the user has it" {
        $script:DFSessionStatus['rustup'] = New-DFToolStatus -Name rustup -State Conflict -RequestedBy 'Tools'
        (& $script:Env @() 'cargo').Count | Should -Be 0
    }
    It "skips a tool the session didn't request" {
        $script:DFSessionStatus.Remove('rustup')
        (& $script:Env @() 'cargo').Count | Should -Be 0
    }
    It 'returns nothing without a session' {
        $script:DFSessionStatus = $null
        (& $script:Env 'bat' 'fnm').Count | Should -Be 0
    }
    It 'lets the later source win a clash, verbosely' {
        $out = Get-DFInstallEnvironment -Tool $script:Db['t1'] -Manager $script:Db['fnm'] -ToolDb $script:Db -Verbose 4>&1
        $verbose = @($out | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $result = $out | Where-Object { $_ -is [System.Collections.IDictionary] }
        $result['FNM_DIR'] | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_DATA_HOME 'fnm'))
        "$verbose" | Should -BeLike '*FNM_DIR*'
    }
}
