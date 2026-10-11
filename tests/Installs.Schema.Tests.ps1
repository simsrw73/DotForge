BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Get-Errs([hashtable]$Extra) {
        $t = [pscustomobject](@{ name = 't'; executable = 't.exe' } + $Extra)
        (Test-DFToolSchema -Tool $t).Errors
    }
    $script:Db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
}

Describe 'installs and install (schema)' {
    It 'accepts a command manager and a function manager' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x'; command = @('x', 'install', '{id}') } } | Should -BeNullOrEmpty
        Get-Errs @{ installs = [pscustomobject]@{ from = 'psgallery'; function = 'Install-PSResource'; args = [pscustomobject]@{ Name = '{id}' } } } | Should -BeNullOrEmpty
    }
    It 'requires from, and exactly one of command or function' {
        Get-Errs @{ installs = [pscustomobject]@{ command = @('x') } } | Should -Match 'installs.from'
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x' } } | Should -Match 'command or function'
    }
    It 'requires install.prefer to name the tool''s own sources' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ prefer = @('winget') } } | Should -Match 'install.prefer'
    }
    It 'accepts a list of blocks, each validated' {
        Get-Errs @{ installs = @([pscustomobject]@{ from = 'pypi'; command = @('uv', 'tool', 'install', '{id}') }, [pscustomobject]@{ from = 'uv'; command = @('uv', 'python', 'install', '{id}') }) } | Should -BeNullOrEmpty
        Get-Errs @{ installs = @([pscustomobject]@{ from = 'pypi'; command = @('x') }, [pscustomobject]@{ command = @('y') }) } | Should -Match 'installs\[1\]\.from'
    }
    It 'normalizes installs to a list of blocks' {
        $one = ConvertTo-DFToolRecord ('{ "name": "m", "executable": "m", "installs": { "from": "m", "command": ["m","i","{id}"] } }' | ConvertFrom-Json)
        @($one.installs).Count | Should -Be 1
        $two = ConvertTo-DFToolRecord ('{ "name": "uv", "executable": "uv", "installs": [ { "from": "pypi", "command": ["uv","tool","install","{id}"] }, { "from": "uv", "command": ["uv","python","install","{id}"] } ] }' | ConvertFrom-Json)
        @($two.installs).Count | Should -Be 2
        $two.installs[1].from | Should -Be 'uv'
        $two.installs[1].batch | Should -BeFalse
    }
    It 'normalizes installs with defaults' {
        $r = ConvertTo-DFToolRecord ('{ "name": "m", "executable": "m", "installs": { "from": "m", "command": ["m","i","{id}"] } }' | ConvertFrom-Json)
        $r.installs.batch | Should -BeFalse
        $r.installs.elevate | Should -BeFalse
        $r.installs.feeds | Should -BeNullOrEmpty
        $r.install | Should -BeNullOrEmpty
    }
}

Describe 'shipped managers' {
    It 'gives every source used in packages a manager whose installs.from names it' {
        $from = @($script:Db.Values | Where-Object installs | ForEach-Object { $_.installs.from })
        $used = @($script:Db.Values | Where-Object packages | ForEach-Object { $_.packages.PSObject.Properties.Name }) | Sort-Object -Unique
        foreach ($s in $used) { $from | Should -Contain $s -Because "a tool uses source '$s'" }
    }
    It 'marks choco as needing elevation and scoop as having feeds' {
        $script:Db['choco'].installs.elevate | Should -BeTrue
        $script:Db['scoop'].installs.feeds.id | Should -Be '{feed}/{id}'
    }
}
