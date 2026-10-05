# The role contract, checked at author time over every shipped tool. See
# docs/superpowers/specs/2026-10-05-roles-v2-design.md §6.
BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $script:ToolCases = @(Get-ChildItem (Join-Path $root 'Tools') -Filter '*.json' | ForEach-Object {
        @{ Name = $_.BaseName; JsonPath = $_.FullName; SidecarPath = [IO.Path]::ChangeExtension($_.FullName, '.ps1') }
    })
}

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:Roles = Get-Content (Join-Path $root 'data/roles.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:AllReservedEnv = @($script:Roles.Values | ForEach-Object { if ($_['reserved']) { $_['reserved']['env'] } } | Where-Object { $_ })
    $script:AllReservedAliases = @($script:Roles.Values | ForEach-Object { if ($_['reserved']) { $_['reserved']['aliases'] } } | Where-Object { $_ })

    function Get-RoleMemberships($JsonPath) {
        $j = Get-Content $JsonPath -Raw | ConvertFrom-Json -AsHashtable
        if ($j['roles']) { $j['roles'] } else { @{} }
    }

    # Every AST node in $Ast that is not inside a function named Initialize-DFRole*.
    function Get-NodesOutsideHooks($Ast, [scriptblock]$Predicate) {
        $Ast.FindAll({ param($n) & $Predicate $n }, $true) | Where-Object {
            $p = $_.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $p.Name -like 'Initialize-DFRole*') { return $false }
                $p = $p.Parent
            }
            $true
        }
    }

    function Get-SidecarAst($Path) {
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }

    function Get-HookNames($Ast) {
        # ForEach-Object, not .Name: member enumeration on no matches yields a lone $null.
        @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*Initialize-DFRole*' }, $true) | ForEach-Object Name)
    }
}

Describe 'Role contract: <Name>' -ForEach $script:ToolCases {
    It 'declares only roles that exist in data/roles.json' {
        foreach ($role in (Get-RoleMemberships $JsonPath).Keys) {
            $script:Roles.ContainsKey($role) | Should -BeTrue -Because "$Name declares unknown role '$role'"
        }
    }

    It 'gives every single-kind membership content or a hook, and category memberships neither' {
        $hooks = if (Test-Path $SidecarPath) { Get-HookNames (Get-SidecarAst $SidecarPath) } else { @() }
        $memberships = Get-RoleMemberships $JsonPath
        foreach ($role in $memberships.Keys) {
            $def = $script:Roles[$role]
            $block = $memberships[$role]
            $hasContent = $block['aliases'] -or $block['env']
            if ($def['kind'] -eq 'single') {
                ($hasContent -or $def['hook'] -in $hooks -or $def['emptyMembership']) |
                    Should -BeTrue -Because "$Name joins '$role' but supplies no aliases, env or $($def['hook'])"
            } else {
                $hasContent | Should -BeFalse -Because "category role '$role' takes no aliases or env"
            }
        }
    }

    It 'defines hooks only for roles it declares, and never as global functions' {
        if (-not (Test-Path $SidecarPath)) { return }
        $declared = @((Get-RoleMemberships $JsonPath).Keys | ForEach-Object { $script:Roles[$_]['hook'] })
        foreach ($h in Get-HookNames (Get-SidecarAst $SidecarPath)) {
            $h | Should -Not -BeLike 'global:*' -Because 'a hook must stay local to the companion call'
            $h | Should -BeIn $declared -Because "$Name defines $h for a role it does not declare"
        }
    }

    It 'sets no role-reserved env var or alias at the top level' {
        $j = Get-Content $JsonPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in @(if ($j['env']) { $j['env'].Keys })) { $k | Should -Not -BeIn $script:AllReservedEnv -Because "$k is reserved for a role; put it in that role's block" }
        foreach ($k in @(if ($j['aliases']) { $j['aliases'].Keys })) { $k | Should -Not -BeIn $script:AllReservedAliases -Because "$k is reserved for a role; put it in that role's block" }
    }

    It 'never assigns a role-reserved env var in its companion, hooks included' {
        if (-not (Test-Path $SidecarPath)) { return }
        $ast = Get-SidecarAst $SidecarPath
        $hits = $ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
             $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
             $n.Left.VariablePath.IsDriveQualified -and $n.Left.VariablePath.DriveName -eq 'Env' -and
             ($n.Left.VariablePath.UserPath -replace '^Env:') -in $script:AllReservedEnv) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
             $n.Member.Value -eq 'SetEnvironmentVariable' -and $n.Arguments.Count -ge 1 -and
             $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
             $n.Arguments[0].Value -in $script:AllReservedEnv)
        }, $true)
        @($hits).Count | Should -Be 0 -Because "reserved variables come only from role blocks: $($hits.Extent.Text -join '; ')"
    }

    It 'uses its roles'' reserved code only inside role hooks' {
        if (-not (Test-Path $SidecarPath)) { return }
        $ast = Get-SidecarAst $SidecarPath
        foreach ($role in (Get-RoleMemberships $JsonPath).Keys) {
            $reserved = $script:Roles[$role]['reserved']
            foreach ($token in @(if ($reserved) { $reserved['code'] })) {
                if (-not $token) { continue }
                $hits = Get-NodesOutsideHooks $ast {
                    param($n)
                    ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $token) -or
                    ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                     $n.Parent -isnot [System.Management.Automation.Language.CommandAst] -and $n.Value -like "*$token*") -or
                    ($token -like 'function:*' -and $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                     ($n.Name -replace '^global:') -eq ($token -replace '^function:'))
                }
                @($hits).Count | Should -Be 0 -Because "'$token' belongs to the $role role and may appear only in its hook: $(@($hits).Extent.Text -join '; ')"
            }
        }
    }
}

Describe 'Role contract: a broken fixture is caught' {
    It 'flags a member that runs Invoke-Expression outside its prompt hook' {
        $path = Join-Path $TestDrive 'bad.ps1'
        'Invoke-Expression (starship init powershell)' | Set-Content $path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $hits = Get-NodesOutsideHooks $ast { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Expression' }
        @($hits).Count | Should -Be 1
    }

    It 'accepts the same call inside the hook' {
        $path = Join-Path $TestDrive 'good.ps1'
        'function Initialize-DFRolePrompt { Invoke-Expression (starship init powershell) }' | Set-Content $path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $hits = Get-NodesOutsideHooks $ast { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Expression' }
        @($hits).Count | Should -Be 0
    }
}
