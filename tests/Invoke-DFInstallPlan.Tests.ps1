BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Expand-DFInstallArgv' {
    It 'expands {id} to every id, and other tokens from values' {
        Expand-DFInstallArgv -Template 'scoop', 'install', '{id}' -Values @{ ids = @('a', 'b') } | Should -Be @('scoop', 'install', 'a', 'b')
        Expand-DFInstallArgv -Template 'scoop', 'bucket', 'add', '{name}', '{url}' -Values @{ name = 'x'; url = 'https://u' } |
            Should -Be @('scoop', 'bucket', 'add', 'x', 'https://u')
    }
    It 'expands {id} inside a token once per id' {
        Expand-DFInstallArgv -Template 'mise', 'use', '-g', 'node@{id}' -Values @{ ids = @('lts') } | Should -Be @('mise', 'use', '-g', 'node@lts')
        Expand-DFInstallArgv -Template 'x', 'pkg@{id}' -Values @{ ids = @('a', 'b') } | Should -Be @('x', 'pkg@a', 'pkg@b')
    }
}

Describe 'Invoke-DFInstallPlan' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Envs = @{}
        $script:Fail = @()
        Mock Invoke-DFManagerCommand {
            $line = ($Argv -join ' ')
            if ($Elevation) { $line = "[$($Elevation.Method)] $line" }
            $script:Calls.Add($line)
            $script:Envs[$line] = @(if ($Environment) { $Environment.Keys })
            [pscustomobject]@{ ExitCode = $(if (@($Argv | Where-Object { $_ -in $script:Fail }).Count) { 1 } else { 0 }); Output = 'out' }
        }
        Mock Update-DFPathFromRegistry { }
        Mock Register-DFTool { }
        Mock Test-DFElevated { $false }
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "xdg": { "method": "env", "vars": { "SCOOP_X": "${XDG_DATA_HOME}/scoop" } }, "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "batch": true, "feeds": { "list": ["scoop","bucket","list"], "add": ["scoop","bucket","add","{name}","{url}"], "id": "{feed}/{id}" } } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "installs": { "from": "choco", "install": ["choco","install","{id}","-y"], "batch": true, "elevate": true } }'),
            (Rec '{ "name": "gsudo", "executable": "gsudo.exe", "roles": { "elevator": {} } }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "xdg": { "method": "env", "vars": { "FNM_DIR": "${XDG_DATA_HOME}/fnm" } }, "packages": { "scoop": "fnm" }, "installs": { "from": "fnm", "install": ["fnm","install","{id}"], "reactivate": true } }'),
            (Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts" } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "xdg": { "method": "env", "vars": { "GLOW_X": "${XDG_CONFIG_HOME}/glow" } }, "packages": { "scoop": "glow", "choco": "glow" } }'),
            (Rec '{ "name": "dotenv", "executable": "Dotenv", "type": "module", "xdg": { "method": "env", "vars": { "DOTENV_X": "${XDG_CONFIG_HOME}/dotenv" } }, "packages": { "scoop": { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://u" } } } }')
        )) { $script:Db[$r.name] = $r }
        # The session requested every tool, so their location variables count (Get-DFInstallEnvironment).
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $script:Db.Keys) { $script:DFSessionStatus[$name] = New-DFToolStatus -Name $name -State Missing -RequestedBy 'Tools' }
        $script:Installed = @('scoop')
        $script:Avail = { param($m) $m.name -in $script:Installed }
        # After a successful install, the tool is "found".
        Mock Test-DFToolAvailable { $true }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'runs one batch per manager, in stage order' {
        $plan = New-DFInstallPlan -Name fnm, glow, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('scoop install fnm glow', 'fnm install lts')
        ($r | Where-Object Result -eq 'Installed').Tool | Should -Be @('fnm', 'glow', 'node')
    }
    It "gives a batch its tools' variables" {
        $plan = New-DFInstallPlan -Name fnm, glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Envs['scoop install fnm glow'] | Should -Contain 'FNM_DIR'
        $script:Envs['scoop install fnm glow'] | Should -Contain 'GLOW_X'
        $script:Envs['scoop install fnm glow'] | Should -Contain 'SCOOP_X'
    }
    It "gives the manager's variables to its own installs" {
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Envs['fnm install lts'] | Should -Contain 'FNM_DIR'
        $script:Envs['fnm install lts'] | Should -Not -Contain 'SCOOP_X'
    }
    It "gives feed commands the manager's variables only, and each command its own" {
        $plan = New-DFInstallPlan -Name dotenv -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Envs['scoop bucket list'] | Should -Be @('SCOOP_X')
        $script:Envs['scoop bucket add insomnia https://u'] | Should -Be @('SCOOP_X')
        $script:Envs['scoop install insomnia/ps-dotenv'] | Should -Contain 'DOTENV_X'
    }
    It 're-activates a manager that asks for it, and merges PATH, after its stage' {
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        Should -Invoke Update-DFPathFromRegistry -Times 2 -Exactly
        Should -Invoke Register-DFTool -Times 1 -ParameterFilter { $Name -contains 'fnm' }
    }
    It 'skips what depends on a failed stage, saying why' {
        $script:Fail = @('fnm')
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq fnm).Result | Should -Be 'Failed'
        ($r | Where-Object Tool -eq node).Result | Should -Be 'Skipped'
        ($r | Where-Object Tool -eq node).Detail | Should -Match 'fnm failed'
        $script:Calls | Should -Not -Contain 'fnm install lts'
    }
    It 'adds a missing feed before installing from it, and not when it is already there' {
        $plan = New-DFInstallPlan -Name dotenv -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('scoop bucket list', 'scoop bucket add insomnia https://u', 'scoop install insomnia/ps-dotenv')

        $script:Calls.Clear()
        Mock Invoke-DFManagerCommand {
            $script:Calls.Add($Argv -join ' ')
            [pscustomobject]@{ ExitCode = 0; Output = $(if ($Argv -contains 'list') { "insomnia https://u`nmain x" } else { '' }) }
        }
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Not -Contain 'scoop bucket add insomnia https://u'
    }
    It 'runs an elevated manager through gsudo when it is installed' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        $script:Installed = @('scoop', 'choco', 'gsudo')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('[Elevator] choco install glow -y')
    }
    It 'falls back to a separate admin window without an elevator' {
        Mock Test-DFInteractiveHost { $true }
        Mock Test-DFWindowsSudoInline { $false }
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        $script:Installed = @('scoop', 'choco')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('[RunAs] choco install glow -y')
    }
    It 'uses the next source when no one can answer an admin prompt' {
        Mock Test-DFInteractiveHost { $false }
        $script:Installed = @('scoop', 'choco')
        Set-DFTestConfig @{ InstallOrder = @('choco', 'scoop') }
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('scoop install glow')
    }
    It 'counts the tools of a failed batch that did install (one bad id doesn''t fail the rest)' {
        $script:Fail = @('glow')
        Mock Test-DFToolAvailable { $Executable -ne 'glow.exe' }
        $plan = New-DFInstallPlan -Name fnm, glow, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq fnm).Result | Should -Be 'Installed'
        ($r | Where-Object Tool -eq glow).Result | Should -Be 'Failed'
        $script:Calls | Should -Contain 'fnm install lts'
    }
    It 'writes the whole output of a failed install under -Verbose' {
        $script:Fail = @('glow')
        Mock Test-DFToolAvailable { $Executable -ne 'glow.exe' }
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $verbose = @(Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        ($verbose.Message -join "`n") | Should -BeLike '*scoop output for glow:*out*'
    }
    It 'says why a dependent was skipped in words' {
        Mock Test-DFToolAvailable { $Executable -ne 'fnm.exe' }
        $plan = New-DFInstallPlan -Name fnm, node -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq node).Detail | Should -Be "skipped: fnm isn't found yet"
    }
    It 'reports a tool that installed but still isn''t found' {
        Mock Test-DFToolAvailable { $false }
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        ($r | Where-Object Tool -eq glow).Result | Should -Be 'NotFound'
        ($r | Where-Object Tool -eq glow).Detail | Should -Match 'open a new shell'
    }
}

Describe 'Update-DFPathFromRegistry' {
    It 'appends only entries the session lacks, and never reorders' {
        $saved = $Env:Path
        try {
            $Env:Path = 'C:\a;C:\b'
            Mock Get-DFRegistryPath { 'C:\b;C:\new' }
            Update-DFPathFromRegistry
            $Env:Path | Should -Be 'C:\a;C:\b;C:\new'
        } finally { $Env:Path = $saved }
    }
}

Describe 'Test-DFInteractiveHost' {
    It 'is false when PowerShell was started with -NonInteractive (or -noni)' {
        Test-DFInteractiveHost -CommandLine @('pwsh', '-NonInteractive', '-File', 'setup.ps1') | Should -BeFalse
        Test-DFInteractiveHost -CommandLine @('pwsh', '-noni', '-c', 'x') | Should -BeFalse
    }
}

Describe 'Invoke-DFInstallPlan with a two-block manager' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-DFManagerCommand { $script:Calls.Add($Argv -join ' '); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Update-DFPathFromRegistry { }
        Mock Register-DFTool { }
        Mock Test-DFElevated { $false }
        Mock Test-DFToolAvailable { $true }
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "uv", "executable": "uv.exe", "installs": [ { "from": "pypi", "install": ["uv","tool","install","{id}"] }, { "from": "uv", "install": ["uv","python","install","--default","{id}"] } ] }'),
            (Rec '{ "name": "ruff", "executable": "ruff.exe", "packages": { "pypi": "ruff" } }'),
            (Rec '{ "name": "python", "executable": "python.exe", "packages": { "uv": "3" } }')
        )) { $script:Db[$r.name] = $r }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }
    It 'runs each tool with the block for its source, in separate batches' {
        $avail = { param($m) $m.name -eq 'uv' }
        $plan = New-DFInstallPlan -Name python, ruff -ToolDb $script:Db -IsAvailable $avail
        @($plan.Stages[0].Batches).Count | Should -Be 2
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $avail
        # Same-stage batches are independent, so their order doesn't matter.
        @($script:Calls | Sort-Object) | Should -Be @('uv python install --default 3', 'uv tool install ruff')
    }
}
