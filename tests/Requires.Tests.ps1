BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # Each companion appends its name, so activation order is observable.
    function script:New-ReqTool([string]$Name, [string]$Extra = '') {
        Set-Content (Join-Path $script:Tools "$Name.json") "{ ""name"": ""$Name"", ""executable"": ""$Name.exe""$Extra }"
        "`$global:DFTestOrder += '$Name'" | Set-Content (Join-Path $script:Tools "$Name.ps1")
    }
}

Describe 'requires (tools and role:<name>)' {
    BeforeEach {
        Reset-DFTestSession
        Set-DFTestXdg
        Set-DFTestConfig $null
        $script:DFToolAvailability = @{}
        $script:Tools = Join-Path $TestDrive "req-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory $script:Tools | Out-Null
        $global:DFTestOrder = @()
        $script:Installed = @()
        Mock Test-DFToolAvailable { $Executable -in $script:Installed }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        Restore-DFTestXdg
        Set-DFTestConfig $null
        Remove-Variable DFTestOrder -Scope Global -ErrorAction Ignore
    }

    It 'requests a required tool automatically and activates it first' {
        New-ReqTool 'app' ', "requires": ["lib"]'
        New-ReqTool 'lib'
        $script:Installed = 'app.exe', 'lib.exe'
        Start-DFSession -Config @{ Tools = @('app') } -ToolsPath $script:Tools 3>$null
        $global:DFTestOrder | Should -Be @('lib', 'app')
        (Get-DFToolStatus -Name lib).RequestedBy | Should -Be 'requires (app)'
    }

    It 'does not activate a tool whose required tool is missing' {
        New-ReqTool 'app' ', "requires": ["lib"]'
        New-ReqTool 'lib'
        $script:Installed = 'app.exe'
        Start-DFSession -Config @{ Tools = @('app') } -ToolsPath $script:Tools 3>$null
        $global:DFTestOrder | Should -BeNullOrEmpty
        (Get-DFToolStatus -Name app).State | Should -Be 'Missing'
        (Get-DFToolStatus -Name app).Detail | Should -Match 'requires lib'
    }

    It 'reports a tool whose required tool is excluded' {
        New-ReqTool 'app' ', "requires": ["lib"]'
        New-ReqTool 'lib'
        $script:Installed = 'app.exe', 'lib.exe'
        Start-DFSession -Config @{ Tools = @('app'); ExcludeTools = @('lib') } -ToolsPath $script:Tools 3>$null
        (Get-DFToolStatus -Name app).State | Should -Be 'Missing'
        (Get-DFToolStatus -Name app).Detail | Should -Match 'requires lib, which is excluded'
    }

    It 'treats a required tool excluded through a +group as excluded' {
        New-ReqTool 'app' ', "requires": ["lib"]'
        New-ReqTool 'lib'
        $script:Installed = 'app.exe', 'lib.exe'
        $script:DFGroupDb = Get-DFGroupDb -Path (New-Item (Join-Path $script:Tools 'groups.txt') -Force -Value '{ "libs": { "description": "d", "tools": ["lib"] } }').FullName
        try {
            Start-DFSession -Config @{ Tools = @('app'); ExcludeTools = @('+libs') } -ToolsPath $script:Tools 3>$null
        } finally { $script:DFGroupDb = $null }
        (Get-DFToolStatus -Name app).Detail | Should -Match 'requires lib, which is excluded'
    }

    Context 'role:js-runtime (npm needs a JavaScript runtime, not a particular one)' {
        It 'orders the tool after the requested member of the role' {
            New-ReqTool 'npmx' ', "requires": ["role:js-runtime"]'
            New-ReqTool 'nodeprov' ', "roles": { "js-runtime": { "priority": 10 } }'
            $script:Installed = 'npmx.exe', 'nodeprov.exe'
            Start-DFSession -Config @{ Tools = @('npmx', 'nodeprov') } -ToolsPath $script:Tools 3>$null
            $global:DFTestOrder | Should -Be @('nodeprov', 'npmx')
        }

        It 'never requests a member on the user''s behalf: which manager or runtime is their choice' {
            New-ReqTool 'npmx' ', "requires": ["role:js-runtime"]'
            New-ReqTool 'provlow' ', "roles": { "js-runtime": { "priority": 10 } }'
            New-ReqTool 'provhigh' ', "roles": { "js-runtime": { "priority": 20 } }'
            $script:Installed = 'npmx.exe', 'provlow.exe', 'provhigh.exe'
            Start-DFSession -Config @{ Tools = @('npmx'); Defaults = @{ 'js-runtime' = 'provlow' } } -ToolsPath $script:Tools 3>$null
            $global:DFTestOrder | Should -Be @('npmx')
            Get-DFToolStatus -Name provlow | Should -BeNullOrEmpty
            Get-DFToolStatus -Name provhigh | Should -BeNullOrEmpty
        }

        It 'does not block the tool when no member is available (a runtime may come from outside DotForge)' {
            New-ReqTool 'npmx' ', "requires": ["role:js-runtime"]'
            New-ReqTool 'provgone' ', "roles": { "js-runtime": { "priority": 30 } }'
            $script:Installed = 'npmx.exe'
            Start-DFSession -Config @{ Tools = @('npmx') } -ToolsPath $script:Tools 3>$null
            (Get-DFToolStatus -Name npmx).State | Should -Be 'Active'
            Get-DFToolStatus -Name provgone | Should -BeNullOrEmpty
        }

        It 'tells the user which tools could fill the role when a tool is missing and no member is requested' {
            New-ReqTool 'npmx' ', "requires": ["role:js-runtime"]'
            New-ReqTool 'provgone' ', "roles": { "js-runtime": { "priority": 30 } }'
            New-ReqTool 'provother' ', "roles": { "js-runtime": {} }'
            Start-DFSession -Config @{ Tools = @('npmx') } -ToolsPath $script:Tools 3>$null
            (Get-DFToolStatus -Name npmx).Detail | Should -Match "needs a js-runtime: add provgone or provother to Tools"
        }

        It 'reads every tool record only when a tool is missing' {
            New-ReqTool 'npmx' ', "requires": ["role:js-runtime"]'
            $script:Installed = 'npmx.exe'
            Mock Get-DFRoleRequirementHint { 'hint' }
            Start-DFSession -Config @{ Tools = @('npmx') } -ToolsPath $script:Tools 3>$null
            Should -Invoke Get-DFRoleRequirementHint -Times 0
        }
    }

    It 'warns about a requires cycle and still activates both tools' {
        New-ReqTool 'a' ', "requires": ["b"]'
        New-ReqTool 'b' ', "requires": ["a"]'
        $script:Installed = 'a.exe', 'b.exe'
        $w = Start-DFSession -Config @{ Tools = @('a') } -ToolsPath $script:Tools 3>&1
        "$w" | Should -Match 'circular'
        @($global:DFTestOrder).Count | Should -Be 2
    }
}

Describe 'shipped requires' {
    It 'names only existing tools and roles' {
        $roles = (Get-Content "$PSScriptRoot/../data/roles.json" -Raw | ConvertFrom-Json).PSObject.Properties.Name
        $tools = (Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json').BaseName
        $bad = foreach ($f in Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json') {
            $r = (Get-Content $f.FullName -Raw | ConvertFrom-Json).PSObject.Properties['requires']?.Value
            foreach ($req in @($r)) {
                if (-not $req) { continue }
                if ($req -like 'role:*') { if ($req.Substring(5) -notin $roles) { "$($f.Name): $req" } }
                elseif ($req -cnotin $tools) { "$($f.Name): $req" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'gives npm and inshellisense a JavaScript runtime, and puts fnm and mise in that role' {
        (Get-Content "$PSScriptRoot/../Tools/npm.json" -Raw | ConvertFrom-Json).requires | Should -Contain 'role:js-runtime'
        (Get-Content "$PSScriptRoot/../Tools/inshellisense.json" -Raw | ConvertFrom-Json).requires | Should -Contain 'role:js-runtime'
        (Get-Content "$PSScriptRoot/../Tools/fnm.json" -Raw | ConvertFrom-Json).roles.'js-runtime' | Should -Not -BeNullOrEmpty
        (Get-Content "$PSScriptRoot/../Tools/mise.json" -Raw | ConvertFrom-Json).roles.'js-runtime' | Should -Not -BeNullOrEmpty
    }
}
