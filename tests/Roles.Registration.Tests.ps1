BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Register-DFTool role activation' {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $global:DFRoleEnvState = $null
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            Set-Variable -Scope Script -Name "Saved$v" -Value ([Environment]::GetEnvironmentVariable("XDG_$($v)_HOME"))
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive $v.ToLower()))
        }
        # TestDrive lives for the whole Describe; a fresh state folder per test keeps
        # one test's "already warned" record from silencing the next test's warning.
        $Env:XDG_STATE_HOME = Join-Path $TestDrive "state-$([guid]::NewGuid())"
        $script:SavedPager = $Env:DF_T_PAGER
        Remove-Item Env:DF_T_PAGER -ErrorAction Ignore
        Set-DFTestConfig $null
        $script:Tools = Join-Path $TestDrive "tools-$([guid]::NewGuid())"
        New-Item -ItemType Directory $script:Tools | Out-Null

        $rolesFile = Join-Path $TestDrive 'roles.json'
        @'
{ "tprompt": { "kind": "single", "exclusive": true, "hook": "Initialize-DFRoleTprompt" },
  "tpager":  { "kind": "single", "hook": "Initialize-DFRoleTpager", "reserved": { "env": ["DF_T_PAGER"] } },
  "tother":  { "kind": "single", "hook": "Initialize-DFRoleTother" },
  "tlisting":{ "kind": "single", "hook": "Initialize-DFRoleTlisting", "reserved": { "aliases": ["tls"] } } }
'@ | Set-Content $rolesFile
        $script:DFRoleDb = Get-DFRoleDb -Path $rolesFile

        function script:Write-Tool([string]$Name, [string]$Json, [string]$Sidecar) {
            $Json | Set-Content (Join-Path $script:Tools "$Name.json")
            if ($Sidecar) { $Sidecar | Set-Content (Join-Path $script:Tools "$Name.ps1") }
        }
        Write-Tool 'alpha' '{ "name": "alpha", "executable": "alpha.exe",
            "roles": { "tprompt": { "priority": 20 }, "tother": { "priority": 0 } },
            "env": { "DF_T_ALPHA_ENV": "1" } }' @'
$global:RoleCalls += 'alpha:body'
function Initialize-DFRoleTprompt { param($Tool, $Role) $global:RoleCalls += "alpha:$Role" }
function Initialize-DFRoleTother  { param($Tool, $Role) $global:RoleCalls += "alpha:$Role" }
'@
        Write-Tool 'beta' '{ "name": "beta", "executable": "beta.exe",
            "roles": { "tprompt": { "priority": 10 }, "tother": { "priority": 50 } } }' @'
$global:RoleCalls += 'beta:body'
function Initialize-DFRoleTprompt { param($Tool, $Role) $global:RoleCalls += "beta:$Role" }
function Initialize-DFRoleTother  { param($Tool, $Role) $global:RoleCalls += "beta:$Role" }
'@
        Write-Tool 'dfrolepager' '{ "name": "dfrolepager", "executable": "dfrolepager.exe",
            "roles": { "tpager": { "env": { "DF_T_PAGER": "dfrolepager --paging" } },
                       "tlisting": { "aliases": { "tls": { "command": "dfrolepager", "args": ["--list"] } } } } }'
        Write-Tool 'dfrolepagerb' '{ "name": "dfrolepagerb", "executable": "dfrolepagerb.exe",
            "roles": { "tlisting": { "priority": -1, "aliases": { "tls": { "command": "dfrolepagerb", "args": [] } } } } }'

        $global:RoleCalls = @()
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Get-Variable -Scope Script -Name "Saved$v").Value)
        }
        if ($null -eq $script:SavedPager) { Remove-Item Env:DF_T_PAGER -ErrorAction Ignore } else { $Env:DF_T_PAGER = $script:SavedPager }
        Remove-Item Env:DF_T_ALPHA_ENV -ErrorAction Ignore
        Set-DFTestConfig $null; Remove-Variable RoleCalls -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function tls
        $script:DFRoleDb = $null
    }

    It 'calls only the winner''s hook, and runs every tool''s body' {
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools -WarningAction SilentlyContinue
        $global:RoleCalls | Should -Contain 'alpha:body'
        $global:RoleCalls | Should -Contain 'beta:body'
        $global:RoleCalls | Should -Contain 'alpha:tprompt'
        $global:RoleCalls | Should -Not -Contain 'beta:tprompt'
    }

    It 'activates a tool in a role it wins even when it lost another' {
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools -WarningAction SilentlyContinue
        $global:RoleCalls | Should -Contain 'beta:tother'
        $global:RoleCalls | Should -Not -Contain 'alpha:tother'
    }

    It 'follows Defaults for the hook' {
        Set-DFTestConfig @{ Defaults = @{ tprompt = 'beta' } }
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools
        $global:RoleCalls | Should -Contain 'beta:tprompt'
        $global:RoleCalls | Should -Not -Contain 'alpha:tprompt'
    }

    It 'still applies a loser''s non-role configuration' {
        Set-DFTestConfig @{ Defaults = @{ tprompt = 'beta' } }
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools
        $Env:DF_T_ALPHA_ENV | Should -Be '1'
    }

    It 'applies the winner''s declarative env and aliases, never a loser''s' {
        Register-DFTool -Name dfrolepager, dfrolepagerb -ToolsPath $script:Tools
        $Env:DF_T_PAGER | Should -Be 'dfrolepager --paging'
        (Get-Command tls).ScriptBlock | Should -Not -BeNullOrEmpty
        function global:dfrolepager { $global:RoleCalls += "dfrolepager:$args" }
        function global:dfrolepagerb { $global:RoleCalls += 'dfrolepagerb' }
        try { tls } finally { Remove-DFTestGlobal -Function dfrolepager, dfrolepagerb }
        $global:RoleCalls | Should -Contain 'dfrolepager:--list'
        $global:RoleCalls | Should -Not -Contain 'dfrolepagerb'
    }

    It 'warns once for an unresolved exclusive role' {
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools -WarningVariable w1 -WarningAction SilentlyContinue
        "$w1" | Should -Match 'tprompt role; using alpha'
        Register-DFTool -Name alpha, beta -ToolsPath $script:Tools -WarningVariable w2 -WarningAction SilentlyContinue
        "$w2" | Should -Not -Match 'tprompt role'
    }

    It 'warns, and continues with later tools, when a won role has no hook and no role-block content' {
        Write-Tool 'nohook' '{ "name": "nohook", "executable": "nohook.exe", "roles": { "tother": { "priority": 99 } } }'
        Register-DFTool -Name nohook, dfrolepager -ToolsPath $script:Tools -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'nohook.*tother.*Initialize-DFRoleTother'
        $Env:DF_T_PAGER | Should -Be 'dfrolepager --paging'
    }

    It 'treats an empty env or aliases block as no content, so a missing hook still warns' {
        Write-Tool 'emptyblock' '{ "name": "emptyblock", "executable": "emptyblock.exe", "roles": { "tother": { "priority": 99, "env": {}, "aliases": {} } } }'
        Register-DFTool -Name emptyblock -ToolsPath $script:Tools -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'emptyblock.*tother.*Initialize-DFRoleTother'
    }

    It 'warns, and continues, when a hook throws' {
        Write-Tool 'boom' '{ "name": "boom", "executable": "boom.exe", "roles": { "tother": { "priority": 99 } } }' @'
function Initialize-DFRoleTother { param($Tool, $Role) throw 'kaboom' }
'@
        Register-DFTool -Name boom, dfrolepager -ToolsPath $script:Tools -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'boom.*tother.*kaboom'
        $Env:DF_T_PAGER | Should -Be 'dfrolepager --paging'
    }

    It 'ignores a same-named global function that does not come from the tool''s own sidecar' {
        function global:Initialize-DFRoleTother { $global:RoleCalls += 'stray' }
        try {
            Write-Tool 'nohook' '{ "name": "nohook", "executable": "nohook.exe", "roles": { "tother": { "priority": 99 } } }'
            Register-DFTool -Name nohook -ToolsPath $script:Tools -WarningAction SilentlyContinue
            $global:RoleCalls | Should -Not -Contain 'stray'
        } finally { Remove-DFTestGlobal -Function 'Initialize-DFRoleTother' }
    }

    It 'expands ${DF_TOOL_EXE} in a won role''s env to the resolved path' {
        Write-Tool 'exetool' '{ "name": "exetool", "executable": "exetool.exe", "roles": { "tpager": { "priority": 99, "env": { "DF_T_PAGER": "${DF_TOOL_EXE}" } } } }'
        Mock Resolve-DFToolExecutable { 'C:\Tools\exetool.exe' }
        Register-DFTool -Name exetool -ToolsPath $script:Tools
        $Env:DF_T_PAGER | Should -Be 'C:/Tools/exetool.exe'
    }

    It 're-running registration calls the winner''s hook again' {
        Register-DFTool -Name alpha -ToolsPath $script:Tools
        Register-DFTool -Name alpha -ToolsPath $script:Tools
        @($global:RoleCalls | Where-Object { $_ -eq 'alpha:tprompt' }).Count | Should -Be 2
    }

    Context 'legacy "role" string (role v1 records)' {
        BeforeEach {
            Write-Tool 'legacytool' '{ "name": "legacytool", "executable": "legacytool.exe", "role": "tlisting", "after": ["dfrolepager"],
                "aliases": { "tls": { "command": "legacytool", "args": ["--legacy"] }, "lonly": { "command": "legacytool", "args": ["--only"] } } }'
            function global:legacytool { $global:RoleCalls += "legacytool:$args" }
            function global:dfrolepager { $global:RoleCalls += "dfrolepager:$args" }
        }
        AfterEach { Remove-DFTestGlobal -Function legacytool, dfrolepager, lonly }

        It 'keeps a legacy winner''s top-level aliases, with no missing-hook warning' {
            Set-DFTestConfig @{ Defaults = @{ tlisting = 'legacytool' } }
            Register-DFTool -Name legacytool, dfrolepager -ToolsPath $script:Tools -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Not -Match 'Initialize-DFRole'
            tls
            $global:RoleCalls | Should -Contain 'legacytool:--legacy'
            $global:RoleCalls | Should -Not -Contain 'dfrolepager:--list'
        }

        It 'suppresses a legacy loser''s reserved top-level aliases, and keeps its others' {
            Set-DFTestConfig @{ Defaults = @{ tlisting = 'dfrolepager' } }
            Register-DFTool -Name legacytool, dfrolepager -ToolsPath $script:Tools -WarningAction SilentlyContinue
            tls
            $global:RoleCalls | Should -Contain 'dfrolepager:--list'
            $global:RoleCalls | Should -Not -Contain 'legacytool:--legacy'
            Test-Path function:global:lonly | Should -BeTrue
        }

        It 'loads a legacy free-form role name quietly' {
            Write-Tool 'oddlegacy' '{ "name": "oddlegacy", "executable": "oddlegacy.exe", "role": "my-own-group" }'
            Register-DFTool -Name oddlegacy -ToolsPath $script:Tools -WarningVariable w -WarningAction SilentlyContinue
            "$w" | Should -Not -Match 'unknown role'
        }
    }
}

Describe 'Get-DFRoleWinners opt-in memberships' {
    BeforeEach { Reset-DFTestSession;
        Set-DFTestConfig $null
        Mock Test-DFToolAvailable { $true }
        $script:RoleDb = @{ 'tab-completion' = [pscustomobject]@{ kind = 'single' } }
        $script:ToolDb = @{
            standard = [pscustomobject]@{ name = 'standard'; executable = 'standard.exe'; type = 'exe'; roles = [pscustomobject]@{ 'tab-completion' = [pscustomobject]@{ priority = 10; optIn = $false } } }
            optional = [pscustomobject]@{ name = 'optional'; executable = 'optional.exe'; type = 'exe'; roles = [pscustomobject]@{ 'tab-completion' = [pscustomobject]@{ priority = 20; optIn = $true } } }
        }
    }
    AfterEach { Set-DFTestConfig $null }

    It 'skips an opt-in candidate unless Defaults names it' {
        $winner = Get-DFRoleWinners -ToolDb $script:ToolDb -Tools $script:ToolDb.Values -RoleDb $script:RoleDb
        $winner['tab-completion'].Winner | Should -Be 'standard'
        $winner['tab-completion'].Candidates | Should -Be @('standard')
    }

    It 'allows Defaults to opt an optional candidate in over a higher-priority standard candidate' {
        Set-DFTestConfig @{ Defaults = @{ 'tab-completion' = 'optional' } }
        $winner = Get-DFRoleWinners -ToolDb $script:ToolDb -Tools $script:ToolDb.Values -RoleDb $script:RoleDb
        $winner['tab-completion'].Winner | Should -Be 'optional'
        $winner['tab-completion'].Reason | Should -Be 'Defaults'
    }

    It 'leaves a sole opt-in candidate without a winner' {
        $winner = Get-DFRoleWinners -ToolDb @{ optional = $script:ToolDb.optional } -Tools @($script:ToolDb.optional) -RoleDb $script:RoleDb
        $winner.ContainsKey('tab-completion') | Should -BeFalse
    }
}
