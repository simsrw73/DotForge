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
    It 'accepts an install-argv manager and a function manager' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x'; install = @('x', 'install', '{id}') } } | Should -BeNullOrEmpty
        Get-Errs @{ installs = [pscustomobject]@{ from = 'psgallery'; function = 'Install-PSResource'; args = [pscustomobject]@{ Name = '{id}' } } } | Should -BeNullOrEmpty
    }
    It 'requires from, and exactly one of install or function' {
        Get-Errs @{ installs = [pscustomobject]@{ install = @('x') } } | Should -Match 'installs.from'
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x' } } | Should -Match 'install or function'
    }
    It 'accepts install.avoid naming a source the tool has, with a reason' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g'; winget = 'w' }; install = [pscustomobject]@{ avoid = [pscustomobject]@{ scoop = 'why' } } } | Should -BeNullOrEmpty
    }
    It 'requires install.avoid to be an object of reasons' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ avoid = 'scoop' } } | Should -Match 'install.avoid must be an object'
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ avoid = [pscustomobject]@{ scoop = 1 } } } | Should -Match 'install.avoid.scoop must be a reason \(text\)'
    }
    It 'requires install.avoid to name the tool''s own sources' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ avoid = [pscustomobject]@{ choco = 'why' } } } |
            Should -Match 'install.avoid names sources the tool has no package for: choco'
    }
    It 'rejects a source both preferred and avoided' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ prefer = @('scoop'); avoid = [pscustomobject]@{ scoop = 'why' } } } |
            Should -Match 'install.prefer and install.avoid both name: scoop'
    }
    It 'normalizes install.avoid to an object, empty when the record has no install block' {
        Set-StrictMode -Version Latest
        $bare = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'b'; executable = 'b.exe' })
        @($bare.install.avoid.PSObject.Properties).Count | Should -Be 0
        $avoids = ConvertTo-DFToolRecord ([pscustomobject]@{ name = 'a'; executable = 'a.exe'; packages = [pscustomobject]@{ scoop = 'a' }; install = [pscustomobject]@{ avoid = [pscustomobject]@{ scoop = 'why' } } })
        $avoids.install.avoid.scoop | Should -Be 'why'
        @($avoids.install.prefer).Count | Should -Be 0
    }
    It 'requires install.prefer to name the tool''s own sources' {
        Get-Errs @{ packages = [pscustomobject]@{ scoop = 'g' }; install = [pscustomobject]@{ prefer = @('winget') } } | Should -Match 'install.prefer'
    }
    It 'accepts a list of blocks, each validated' {
        Get-Errs @{ installs = @([pscustomobject]@{ from = 'pypi'; install = @('uv', 'tool', 'install', '{id}') }, [pscustomobject]@{ from = 'uv'; install = @('uv', 'python', 'install', '{id}') }) } | Should -BeNullOrEmpty
        Get-Errs @{ installs = @([pscustomobject]@{ from = 'pypi'; install = @('x') }, [pscustomobject]@{ install = @('y') }) } | Should -Match 'installs\[1\]\.from'
    }
    It 'normalizes installs to a list of blocks' {
        $one = ConvertTo-DFToolRecord ('{ "name": "m", "executable": "m", "installs": { "from": "m", "install": ["m","i","{id}"] } }' | ConvertFrom-Json)
        @($one.installs).Count | Should -Be 1
        $two = ConvertTo-DFToolRecord ('{ "name": "uv", "executable": "uv", "installs": [ { "from": "pypi", "install": ["uv","tool","install","{id}"] }, { "from": "uv", "install": ["uv","python","install","{id}"] } ] }' | ConvertFrom-Json)
        @($two.installs).Count | Should -Be 2
        $two.installs[1].from | Should -Be 'uv'
        $two.installs[1].batch | Should -BeFalse
    }
    It 'normalizes installs with defaults' {
        $r = ConvertTo-DFToolRecord ('{ "name": "m", "executable": "m", "installs": { "from": "m", "install": ["m","i","{id}"] } }' | ConvertFrom-Json)
        $r.installs.batch | Should -BeFalse
        $r.installs.elevate | Should -BeFalse
        $r.installs.feeds | Should -BeNullOrEmpty
        @($r.install.prefer).Count | Should -Be 0
        @($r.install.avoid.PSObject.Properties).Count | Should -Be 0
    }
}

Describe 'installs operations' {
    It 'rejects the old command field, naming the new one' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'scoop'; command = @('scoop', 'install', '{id}') } } | Should -Match 'installs.command was renamed to installs.install'
    }
    It 'accepts install, update and remove argv, and list/outdated function names' {
        Get-Errs @{ installs = [pscustomobject]@{
            from = 'scoop'; install = @('scoop', 'install', '{id}'); update = @('scoop', 'update', '{id}')
            remove = @('scoop', 'uninstall', '{id}'); list = 'Get-DFScoopInstalled'; outdated = 'Get-DFScoopOutdated' } } | Should -BeNullOrEmpty
    }
    It 'accepts update and remove as a function with args' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'psgallery'; function = 'Install-PSResource'; args = [pscustomobject]@{ Name = '{id}' }
            update = [pscustomobject]@{ function = 'Update-PSResource'; args = [pscustomobject]@{ Name = '{id}' } } } } | Should -BeNullOrEmpty
    }
    It 'rejects an update that is neither argv nor a function' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'x'; install = @('x'); update = 'x update' } } | Should -Match 'installs.update must be an array \(argv\) or \{ function, args \}'
    }
    It 'rejects a list that is not a function name' {
        Get-Errs @{ installs = [pscustomobject]@{ from = 'scoop'; install = @('scoop', 'install', '{id}'); list = @('scoop', 'list') } } | Should -Match 'installs.list must be a function name'
    }
    It 'normalizes every installs operation' {
        $raw = '{ "name": "m", "executable": "m.exe", "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "update": ["scoop","update","{id}"], "list": "Get-X" } }' | ConvertFrom-Json
        $b = @((ConvertTo-DFToolRecord $raw).installs)[0]
        $b.install | Should -Be @('scoop', 'install', '{id}')
        $b.update | Should -Be @('scoop', 'update', '{id}')
        $b.remove | Should -BeNullOrEmpty
        $b.list | Should -Be 'Get-X'
        $b.outdated | Should -BeNullOrEmpty
        $b.PSObject.Properties['command'] | Should -BeNullOrEmpty
    }
    It 'normalizes a function operation to { function; args }' {
        $raw = '{ "name": "m", "executable": "m", "installs": { "from": "psgallery", "function": "Install-PSResource", "remove": { "function": "Uninstall-PSResource", "args": { "Name": "{id}" } } } }' | ConvertFrom-Json
        $b = @((ConvertTo-DFToolRecord $raw).installs)[0]
        $b.remove.function | Should -Be 'Uninstall-PSResource'
        $b.remove.args.Name | Should -Be '{id}'
    }
}

Describe 'shipped managers' {
    It 'updates crates without --force, which would rebuild every crate every time' {
        $script:Db['cargo'].installs[0].update | Should -Not -Contain '--force'
    }
    It 'calls PSResourceGet by module-qualified name (an old PowerShellGet can shadow it)' {
        $block = $script:Db['psresource'].installs[0]
        $block.function | Should -BeLike 'Microsoft.PowerShell.PSResourceGet\*'
        $block.update.function | Should -BeLike 'Microsoft.PowerShell.PSResourceGet\*'
        $block.remove.function | Should -BeLike 'Microsoft.PowerShell.PSResourceGet\*'
    }
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
