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
}

Describe 'Invoke-DFInstallPlan' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Fail = @()
        Mock Invoke-DFInstallCommand {
            $line = ($Argv -join ' ')
            if ($Elevate) { $line = "[elevated] $line" }
            $script:Calls.Add($line)
            [pscustomobject]@{ ExitCode = $(if (@($Argv | Where-Object { $_ -in $script:Fail }).Count) { 1 } else { 0 }); Output = 'out' }
        }
        Mock Update-DFPathFromRegistry { }
        Mock Register-DFTool { }
        Mock Test-DFElevated { $false }
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "installs": { "from": "scoop", "command": ["scoop","install","{id}"], "batch": true, "feeds": { "list": ["scoop","bucket","list"], "add": ["scoop","bucket","add","{name}","{url}"], "id": "{feed}/{id}" } } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "installs": { "from": "choco", "command": ["choco","install","{id}","-y"], "batch": true, "elevate": true } }'),
            (Rec '{ "name": "gsudo", "executable": "gsudo.exe" }'),
            (Rec '{ "name": "fnm", "executable": "fnm.exe", "packages": { "scoop": "fnm" }, "installs": { "from": "fnm", "command": ["fnm","install","{id}"], "reactivate": true } }'),
            (Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts" } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow", "choco": "glow" } }'),
            (Rec '{ "name": "dotenv", "executable": "Dotenv", "type": "module", "packages": { "scoop": { "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://u" } } } }')
        )) { $script:Db[$r.name] = $r }
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
        Mock Invoke-DFInstallCommand {
            $script:Calls.Add($Argv -join ' ')
            [pscustomobject]@{ ExitCode = 0; Output = $(if ($Argv -contains 'list') { "insomnia https://u`nmain x" } else { '' }) }
        }
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Not -Contain 'scoop bucket add insomnia https://u'
    }
    It 'runs an elevated manager through gsudo when it is installed, and skips it otherwise' {
        Set-DFTestConfig @{ InstallVia = @{ glow = 'choco' } }
        $script:Installed = @('scoop', 'choco', 'gsudo')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $null = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -Be @('[elevated] choco install glow -y')

        $script:Calls.Clear(); $script:Installed = @('scoop', 'choco')
        $plan = New-DFInstallPlan -Name glow -ToolDb $script:Db -IsAvailable $script:Avail
        $r = Invoke-DFInstallPlan -Plan $plan -ToolDb $script:Db -IsAvailable $script:Avail
        $script:Calls | Should -BeNullOrEmpty
        ($r | Where-Object Tool -eq glow).Detail | Should -Match 'elevated shell.*gsudo'
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
