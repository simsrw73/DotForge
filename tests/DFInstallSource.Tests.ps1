BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
    function script:New-Db {
        $db = @{}
        foreach ($r in @(
            (Rec '{ "name": "scoop", "executable": "scoop.cmd", "roles": { "package-manager": { "priority": 30 } }, "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "batch": true } }'),
            (Rec '{ "name": "winget", "executable": "winget.exe", "roles": { "package-manager": { "priority": 20 } }, "installs": { "from": "winget", "install": ["winget","install","{id}"] } }'),
            (Rec '{ "name": "choco", "executable": "choco.exe", "roles": { "package-manager": { "priority": 10 } }, "installs": { "from": "choco", "install": ["choco","install","{id}"], "elevate": true } }'),
            (Rec '{ "name": "npm", "executable": "npm.cmd", "roles": { "js-package-manager": { "priority": 30 } }, "installs": { "from": "npm", "install": ["npm","i","-g","{id}"] } }'),
            (Rec '{ "name": "pnpm", "executable": "pnpm.cmd", "roles": { "js-package-manager": { "priority": 20 } }, "installs": { "from": "npm", "install": ["pnpm","add","-g","{id}"] } }'),
            (Rec '{ "name": "glow", "executable": "glow.exe", "packages": { "scoop": "glow", "winget": "charm.glow", "choco": "glow" }, "install": { "prefer": ["winget"] } }'),
            (Rec '{ "name": "ish", "executable": "is.cmd", "packages": { "npm": "@microsoft/inshellisense" } }'),
            (Rec '{ "name": "psresource", "executable": "Microsoft.PowerShell.PSResourceGet", "type": "module", "installs": { "from": "psgallery", "function": "Install-PSResource", "args": { "Name": "{id}" } } }'),
            (Rec '{ "name": "mod", "executable": "Mod", "type": "module", "packages": { "psgallery": "Mod" } }'),
            (Rec '{ "name": "wgonly", "executable": "wg.exe", "packages": { "winget": "Only.Winget" } }'),
            (Rec '{ "name": "fd", "executable": "fd.exe", "packages": { "scoop": "fd", "winget": "sharkdp.fd", "choco": "fd" }, "install": { "avoid": { "choco": "choco is bad here" } } }')
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
    It 'uses only the sources IncludeSources lists, in the usual order' {
        Set-DFTestConfig @{ IncludeSources = @('choco', 'scoop') }
        Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('scoop', 'choco')
    }
    It 'applies IncludeSources to registries too' {
        Set-DFTestConfig @{ IncludeSources = @('scoop') }
        @(Get-DFInstallSourceOrder -Tool $script:Db.mod -ToolDb $script:Db).Count | Should -Be 0
        Set-DFTestConfig @{ IncludeSources = @('scoop', 'psgallery') }
        Get-DFInstallSourceOrder -Tool $script:Db.mod -ToolDb $script:Db | Should -Be @('psgallery')
    }
    It 'says IncludeSources left nothing for a tool' {
        Set-DFTestConfig @{ IncludeSources = @('scoop') }
        (Resolve-DFInstallSource -Tool $script:Db.wgonly -ToolDb $script:Db -IsAvailable $script:All).Gap |
            Should -Be "no source left (only winget has it, and IncludeSources doesn't list it)"
        Set-DFTestConfig @{ IncludeSources = @('scoop', 'winget'); ExcludeSources = @('winget') }
        (Resolve-DFInstallSource -Tool $script:Db.wgonly -ToolDb $script:Db -IsAvailable $script:All).Gap |
            Should -Be 'no source left (only winget has it, and ExcludeSources removes it)'
        $two = Rec '{ "name": "two", "executable": "two.exe", "packages": { "winget": "Two.Two", "choco": "two" } }'
        (Resolve-DFInstallSource -Tool $two -ToolDb $script:Db -IsAvailable $script:All).Gap |
            Should -Be 'no source left (only winget, choco have it, and IncludeSources and ExcludeSources rule them out)'
    }
    It 'lets InstallVia and -Via name a source IncludeSources leaves out' {
        Set-DFTestConfig @{ IncludeSources = @('scoop'); InstallVia = @{ glow = 'winget' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db)[0] | Should -Be 'winget'
        (Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db -Via @{ glow = 'choco' })[0] | Should -Be 'choco'
    }
    It "doesn't let a bad InstallVia pin loosen IncludeSources" {
        Set-DFTestConfig @{ IncludeSources = @('scoop'); InstallVia = @{ wgonly = 'npm' } }
        @(Get-DFInstallSourceOrder -Tool $script:Db.wgonly -ToolDb $script:Db 3>$null).Count | Should -Be 0
    }
    It 'warns about an unknown IncludeSources entry once per install, and ignores it' {
        Set-DFTestConfig @{ IncludeSources = @('scoop', 'nope') }
        $script:DFInstallWarned = [System.Collections.Generic.HashSet[string]]::new()
        try {
            $first = Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db -WarningVariable w1 3>$null
            $null = Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db -WarningVariable w2 3>$null
        } finally { $script:DFInstallWarned = $null }
        $first | Should -Be @('scoop')
        "$w1" | Should -Match "IncludeSources.*nope"
        @($w2).Count | Should -Be 0
    }
    It 'reads install.avoid under StrictMode Latest, empty or not' {
        Set-StrictMode -Version Latest
        try {
            Get-DFInstallSourceOrder -Tool $script:Db.glow -ToolDb $script:Db | Should -Be @('winget', 'scoop', 'choco')
            Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db | Should -Be @('scoop', 'winget', 'choco')
            (Test-DFToolSchema -Tool ([pscustomobject]@{ name = 't'; executable = 't.exe'; packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ avoid = [pscustomobject]@{} } })).Errors |
                Should -BeNullOrEmpty
        } finally { Set-StrictMode -Off }
    }
    It 'ranks an avoided source last' {
        Set-DFTestConfig @{ InstallOrder = @('choco', 'scoop') }
        Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db | Should -Be @('scoop', 'winget', 'choco')
    }
    It 'keeps an avoided source first when the user names it' {
        (Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db -Via @{ fd = 'choco' })[0] | Should -Be 'choco'
        Set-DFTestConfig @{ InstallVia = @{ fd = 'choco' } }
        (Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db)[0] | Should -Be 'choco'
    }
    It 'still uses an avoided source when IncludeSources allows nothing else' {
        Set-DFTestConfig @{ IncludeSources = @('choco') }
        Get-DFInstallSourceOrder -Tool $script:Db.fd -ToolDb $script:Db | Should -Be @('choco')
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
    It 'still installs from an avoided source when nothing else is available, naming the reason' {
        $r = Resolve-DFInstallSource -Tool $script:Db.fd -ToolDb $script:Db -IsAvailable { param($m) $m.name -eq 'choco' }
        $r.Source | Should -Be 'choco'
        $r.AvoidReason | Should -Be 'choco is bad here'
    }
    It 'has no AvoidReason for an ordinary source' {
        (Resolve-DFInstallSource -Tool $script:Db.fd -ToolDb $script:Db -IsAvailable $script:All).AvoidReason | Should -BeNullOrEmpty
    }
    It 'reports a tool with no packages at all' {
        $db = New-Db
        $db.bare = Rec '{ "name": "bare", "executable": "b.exe" }'
        (Resolve-DFInstallSource -Tool $db.bare -ToolDb $db -IsAvailable $script:All).Gap | Should -Match 'no package'
    }
}

Describe 'managers with several installs blocks' {
    BeforeEach {
        Set-DFTestConfig $null
        $script:Db = @{}
        foreach ($r in @(
            (Rec '{ "name": "uv", "executable": "uv.exe", "roles": { "version-manager": {}, "python-package-manager": { "priority": 30 } }, "installs": [ { "from": "pypi", "install": ["uv","tool","install","{id}"] }, { "from": "uv", "install": ["uv","python","install","--default","{id}"] } ] }'),
            (Rec '{ "name": "ruff", "executable": "ruff.exe", "packages": { "pypi": "ruff" } }'),
            (Rec '{ "name": "python", "executable": "python.exe", "packages": { "uv": "3" } }')
        )) { $script:Db[$r.name] = $r }
    }
    AfterEach { Set-DFTestConfig $null }
    It 'picks the block that installs from the chosen source' {
        $r = Resolve-DFInstallSource -Tool $script:Db.ruff -ToolDb $script:Db -IsAvailable { param($m) $true }
        $r.Manager.name | Should -Be 'uv'
        $r.Block.install | Should -Be @('uv', 'tool', 'install', '{id}')
        (Resolve-DFInstallSource -Tool $script:Db.python -ToolDb $script:Db -IsAvailable { param($m) $true }).Block.from | Should -Be 'uv'
    }
    It 'lists every block''s source in the built-in order' {
        Get-DFBuiltInSourceOrder -ToolDb $script:Db | Should -Contain 'pypi'
        Get-DFBuiltInSourceOrder -ToolDb $script:Db | Should -Contain 'uv'
    }
}

Describe 'shipped Python managers (install spec, Python tree)' {
    BeforeAll { $script:Ship = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force }
    BeforeEach { Set-DFTestConfig $null }
    It 'serves PyPI with uv, then pipx, then pip' {
        (Get-DFSourceManager -Source pypi -ToolDb $script:Ship).name | Should -Be @('uv', 'pipx', 'pip')
    }
    It 'installs python through pymanager first, then uv, and checks it after the version managers' {
        $script:Ship.python.install.prefer[0..1] | Should -Be @('pymanager', 'uv')
        $script:Ship.python.after | Should -Contain 'role:version-manager'
        $script:Ship.python.roles.PSObject.Properties.Name | Should -Contain 'python-runtime'
        $script:Ship.pymanager.roles.PSObject.Properties.Name | Should -Contain 'version-manager'
    }
    It 'finds pipx whether scoop installed it (pipx.cmd) or pip did (pipx.exe)' {
        $script:Ship.pipx.executable | Should -Be 'pipx'
    }
    It 'makes pip come with python, and pipx need a Python runtime' {
        $script:Ship.pip.requires | Should -Contain 'python'
        $script:Ship.pipx.requires | Should -Contain 'role:python-runtime'
    }
    It 'gives a PyPI catalog hint from the top PyPI manager' {
        Mock Import-DFToolDb { $script:Ship }
        Get-DFInstallHint -Source pypi -Id ruff | Should -Be 'uv tool install ruff'
    }
}
