BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
}

Describe 'Register-DFTool' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedCacheHome  = $Env:XDG_CACHE_HOME
        $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config'
        $Env:XDG_CACHE_HOME  = Join-Path $TestDrive 'cache'

        # Create a minimal test tools directory
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "testtool",
  "executable": "testtool.exe",
  "xdg": {
    "compliance": "partial",
    "method": "env",
    "vars": { "TESTTOOL_CONFIG": "${XDG_CONFIG_HOME}/testtool/config.conf" },
    "dirs": ["${XDG_CONFIG_HOME}/testtool"]
  },
  "aliases": {
    "tt": { "command": "testtool", "args": [] },
    "tt-v": { "command": "testtool", "args": ["--verbose"] }
  },
  "picker": {
    "alias": "ftt",
    "function": "Select-TestTool",
    "list": "testtool list",
    "preview_window": "hidden",
    "header": "Select item",
    "action": "testtool show {}"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'testtool.json')
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:XDG_CACHE_HOME  = $script:SavedCacheHome
        Remove-Item Env:\TESTTOOL_CONFIG -ErrorAction Ignore
        Remove-Alias tt -Force -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:tt-v'            -ErrorAction Ignore
        Remove-Item 'function:global:Select-TestTool' -ErrorAction Ignore
        Remove-Alias ftt -Force -Scope Global -ErrorAction Ignore
    }

    It 'skips tools not found on PATH (no error)' {
        Mock Get-Command { $null }
        { Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools } |
            Should -Not -Throw
    }

    It 'sets XDG env vars when method is env' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Env:TESTTOOL_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'testtool' 'config.conf')
    }

    It 'creates XDG dirs when method is env' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'testtool') -PathType Container |
            Should -BeTrue
    }

    It 'creates a Set-Alias for zero-arg aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias tt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'creates a wrapper function for arg-bearing aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:tt-v' | Should -BeTrue
    }

    It 'wrapper function overrides a pre-existing alias of the same name' {
        # Regression: a built-in alias (e.g. ls -> Get-ChildItem) outranks a
        # function in command resolution, so an arg-bearing alias must remove
        # the colliding alias before defining its wrapper function.
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Set-Alias -Name 'tt-v' -Value Get-ChildItem -Scope Global -Force
        try {
            Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
            # Alias > Function in resolution, so the colliding alias must be
            # gone and the wrapper function present for the wrapper to win.
            Test-Path 'Alias:\tt-v'          | Should -BeFalse
            Test-Path 'function:global:tt-v' | Should -BeTrue
        } finally {
            Remove-Alias 'tt-v' -Force -Scope Global -ErrorAction Ignore
        }
    }

    It 'generated wrapper forwards caller arguments after the configured args' {
        # Regression: the wrapper must splat the JSON args and then the caller's
        # own arguments, so a path arrives as a separate positional. eza's
        # --icons/--hyperlink take an optional value, so a trailing bare flag
        # would otherwise consume the path (see Tools/eza.json).
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        # The wrapper resolves its command by name at call time, so a global
        # function named 'testtool' stands in for the real executable.
        function global:testtool { $global:TTCaptured = $args }
        try {
            Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
            & 'tt-v' 'somepath'
            $global:TTCaptured | Should -Be @('--verbose', 'somepath')
        } finally {
            Remove-Item 'function:global:testtool' -ErrorAction Ignore
            Remove-Variable -Name TTCaptured -Scope Global -ErrorAction Ignore
        }
    }

    It 'creates a global picker function from declarative picker JSON' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:Select-TestTool' | Should -BeTrue
    }

    It 'creates a picker alias when picker.alias is set' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias ftt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'dot-sources a companion .ps1 when it exists' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
# Create a companion that sets a sentinel variable
        '$global:CompanionLoaded = $true' |
            Set-Content (Join-Path $script:TmpTools 'testtool.ps1')
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Global:CompanionLoaded | Should -BeTrue
        Remove-Variable CompanionLoaded -Scope Global -ErrorAction Ignore
    }

    It 'warns for unknown tool name' {
        Register-DFTool -Name 'nosuch' -ToolsPath $script:TmpTools `
            -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'nosuch' } | Should -Not -BeNullOrEmpty
    }

    It 'registers all installed tools when -All is specified' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
{ Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'finalizes completion ownership after registering completion tools' {
        @'
{ "name": "carapace", "executable": "carapace.exe" }
'@ | Set-Content (Join-Path $script:TmpTools 'carapace.json')
        @'
{ "name": "PSFzf", "type": "module", "executable": "PSFzf" }
'@ | Set-Content (Join-Path $script:TmpTools 'PSFzf.json')
        '$null = $null' | Set-Content (Join-Path $script:TmpTools 'carapace.ps1')
        '$null = $null' | Set-Content (Join-Path $script:TmpTools 'PSFzf.ps1')
        $script:DFToolDb = $null

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Get-Module { [PSCustomObject]@{ Name = 'PSFzf' } }
        Mock Initialize-DFCompletionStack {}

        Register-DFTool -All -ToolsPath $script:TmpTools

        Should -Invoke Initialize-DFCompletionStack -Times 1 -ParameterFilter {
            @($RegisteredTools) -contains 'carapace' -and
            @($RegisteredTools) -contains 'PSFzf'
        }
    }

    It 'skips tools listed in $Global:DFConfig.SkipTools when -All is used' {
        @'
{ "name": "skiptool", "executable": "skiptool.exe" }
'@ | Set-Content (Join-Path $script:TmpTools 'skiptool.json')
        $script:DFToolDb = $null

        $Global:DFConfig = @{ SkipTools = @('skiptool') }
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        Mock Register-ArgumentCompleter { }

        Register-DFTool -All -ToolsPath $script:TmpTools
        Should -Invoke Get-Command -ParameterFilter { $Name -eq 'skiptool.exe' } -Times 0

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'skiptool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'does not skip tools when $Global:DFConfig is not set' {
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
{ Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
    }

    It 'tolerates $Global:DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        $Global:DFConfig = $null
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\tool.exe' } }
        { Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
    }

    It 'list_accepts_path: creates picker function without error (path safety)' {
        @'
{
  "name": "pathtool",
  "executable": "pathtool.exe",
  "picker": {
    "alias": "fpt",
    "function": "Select-PathTool",
    "list": "eza --icons -1",
    "list_accepts_path": true,
    "preview_window": "right:60%",
    "header": "Select"
  }
}
'@ | Set-Content (Join-Path $script:TmpTools 'pathtool.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\pathtool.exe' } }
{ Register-DFTool -Name 'pathtool' -ToolsPath $script:TmpTools } | Should -Not -Throw
        Test-Path 'function:global:Select-PathTool' | Should -BeTrue

        Remove-Item 'function:global:Select-PathTool' -ErrorAction Ignore
        Remove-Alias fpt -Scope Global -Force -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'pathtool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'xdg method config: creates config file if it does not exist' {
        $configPath = Join-Path $TestDrive 'cfgtool' 'config.conf'
        $escapedPath = $configPath -replace '\\', '/'
        @"
{
  "name": "cfgtool",
  "executable": "cfgtool.exe",
  "xdg": {
    "compliance": "partial",
    "method": "config",
    "config_path": "$escapedPath",
    "config_content": "# default config"
  }
}
"@ | Set-Content (Join-Path $script:TmpTools 'cfgtool.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\cfgtool.exe' } }
        Register-DFTool -Name 'cfgtool' -ToolsPath $script:TmpTools
        Test-Path $configPath | Should -BeTrue
        Get-Content $configPath | Should -Be '# default config'

        Remove-Item (Join-Path $script:TmpTools 'cfgtool.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'uses Get-Module -ListAvailable for type=module tools' {
        @'
{ "name": "mymod", "type": "module", "executable": "MyModule" }
'@ | Set-Content (Join-Path $script:TmpTools 'mymod.json')
        $script:DFToolDb = $null

        Mock Get-Module { $null }
        { Register-DFTool -Name 'mymod' -ToolsPath $script:TmpTools } | Should -Not -Throw
        Mock Get-Module { [PSCustomObject]@{ Name = 'MyModule' } }
        { Register-DFTool -Name 'mymod' -ToolsPath $script:TmpTools } | Should -Not -Throw

        Remove-Item (Join-Path $script:TmpTools 'mymod.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'xdg method config: does not overwrite existing config file' {
        $configPath = Join-Path $TestDrive 'cfgtool2' 'config.conf'
        New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
        'user content' | Set-Content $configPath
        $escapedPath = $configPath -replace '\\', '/'
        @"
{
  "name": "cfgtool2",
  "executable": "cfgtool2.exe",
  "xdg": {
    "compliance": "partial",
    "method": "config",
    "config_path": "$escapedPath",
    "config_content": "# default config"
  }
}
"@ | Set-Content (Join-Path $script:TmpTools 'cfgtool2.json')

        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\cfgtool2.exe' } }
        Register-DFTool -Name 'cfgtool2' -ToolsPath $script:TmpTools
        Get-Content $configPath | Should -Be 'user content'

        Remove-Item (Join-Path $script:TmpTools 'cfgtool2.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'registers psreadline before PSFzf when PSFzf has dependsOn = ["psreadline"]' {
        @'
{ "name": "psreadline", "type": "module", "executable": "PSReadLine", "dependsOn": [] }
'@ | Set-Content (Join-Path $script:TmpTools 'psreadline.json')

        @'
{ "name": "PSFzf", "type": "module", "executable": "PSFzf", "dependsOn": ["psreadline"] }
'@ | Set-Content (Join-Path $script:TmpTools 'PSFzf.json')

        # Record registration order via sentinels
        "`$global:RegOrder.Add('psreadline')" |
            Set-Content (Join-Path $script:TmpTools 'psreadline.ps1')
        "`$global:RegOrder.Add('PSFzf')" |
            Set-Content (Join-Path $script:TmpTools 'PSFzf.ps1')

        $Global:RegOrder = [System.Collections.Generic.List[string]]::new()
        Mock Get-Module { [PSCustomObject]@{ Name = $Name } }
        Register-DFTool -All -ToolsPath $script:TmpTools

        $Global:RegOrder[0] | Should -Be 'psreadline'
        $Global:RegOrder[1] | Should -Be 'PSFzf'

        Remove-Variable RegOrder -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'psreadline.json') -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'PSFzf.json')      -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'psreadline.ps1')  -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'PSFzf.ps1')       -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'injects $DFCurrentTool before dot-sourcing companion' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        '$global:CapturedTool = $DFCurrentTool' |
            Set-Content (Join-Path $script:TmpTools 'testtool.ps1')

        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Global:CapturedTool | Should -Not -BeNullOrEmpty
        $Global:CapturedTool.name | Should -Be 'testtool'

        Remove-Variable CapturedTool -Scope Global -ErrorAction Ignore
        Remove-Item (Join-Path $script:TmpTools 'testtool.ps1') -ErrorAction Ignore
    }

    It 'collapses the ../ in the default ToolsPath' {
        # With no -ToolsPath, the default is Join-Path $PSScriptRoot '../Tools'; it must
        # resolve to a canonical path with no '..' segment. Registering an absent tool by
        # name exercises the resolver without needing a real binary.
        { Register-DFTool -Name '___nope___' } | Should -Not -Throw
        # The resolved path is internal; assert the observable rule via a real tools dir:
        $canon = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
        $canon | Should -Not -Match '\.\.'
    }
}

Describe 'Invoke-DFTopoSort' {
    It 'returns tools unchanged when no dependsOn fields present' {
        $tools = @(
            [PSCustomObject]@{ name = 'zzz' },
            [PSCustomObject]@{ name = 'aaa' }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'zzz'
        $result[1].name | Should -Be 'aaa'
    }

    It 'places dependency before dependent tool' {
        $tools = @(
            [PSCustomObject]@{ name = 'PSFzf';    dependsOn = @('psreadline') },
            [PSCustomObject]@{ name = 'psreadline'; dependsOn = @() }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'psreadline'
        $result[1].name | Should -Be 'PSFzf'
    }

    It 'handles three-tool chain: a -> b -> c' {
        $tools = @(
            [PSCustomObject]@{ name = 'c'; dependsOn = @('b') },
            [PSCustomObject]@{ name = 'a'; dependsOn = @() },
            [PSCustomObject]@{ name = 'b'; dependsOn = @('a') }
        )
        $result = Invoke-DFTopoSort -Tools $tools
        $result[0].name | Should -Be 'a'
        $result[1].name | Should -Be 'b'
        $result[2].name | Should -Be 'c'
    }

    It 'ignores dep not present in the tool set (no error, tool still registered)' {
        $tools = @(
            [PSCustomObject]@{ name = 'PSFzf'; dependsOn = @('psreadline') }
        )
        { $result = Invoke-DFTopoSort -Tools $tools } | Should -Not -Throw
        $result = Invoke-DFTopoSort -Tools $tools
        $result | Should -HaveCount 1
        $result[0].name | Should -Be 'PSFzf'
    }

    It 'emits a warning and returns original order on cycle' {
        $tools = @(
            [PSCustomObject]@{ name = 'a'; dependsOn = @('b') },
            [PSCustomObject]@{ name = 'b'; dependsOn = @('a') }
        )
        $warns = $null
        $result = Invoke-DFTopoSort -Tools $tools -WarningVariable warns 3>$null
        $warns | Should -Not -BeNullOrEmpty
        $result | Should -HaveCount 2
    }

    It 'returns empty array for empty input' {
        $result = Invoke-DFTopoSort -Tools @()
        $result | Should -HaveCount 0
    }
}
