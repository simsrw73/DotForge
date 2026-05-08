BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Public/Get-DFCachedCompletion.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
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
  "completions": { "type": "static", "flags": ["--verbose", "--output"] },
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
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        $Env:TESTTOOL_CONFIG | Should -Be "$($Env:XDG_CONFIG_HOME)/testtool/config.conf"
    }

    It 'creates XDG dirs when method is env' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'testtool') -PathType Container |
            Should -BeTrue
    }

    It 'registers static completions via Register-ArgumentCompleter' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { } -Verifiable
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Should -Invoke Register-ArgumentCompleter -Times 1
    }

    It 'creates a Set-Alias for zero-arg aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias tt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'creates a wrapper function for arg-bearing aliases' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:tt-v' | Should -BeTrue
    }

    It 'creates a global picker function from declarative picker JSON' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Test-Path 'function:global:Select-TestTool' | Should -BeTrue
    }

    It 'creates a picker alias when picker.alias is set' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
        Register-DFTool -Name 'testtool' -ToolsPath $script:TmpTools
        Get-Alias ftt -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'dot-sources a companion .ps1 when it exists' {
        Mock Get-Command { [PSCustomObject]@{ Path = 'C:\fake\testtool.exe' } }
        Mock Register-ArgumentCompleter { }
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
        Mock Register-ArgumentCompleter { }
        { Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
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
        Mock Register-ArgumentCompleter { }
        { Register-DFTool -All -ToolsPath $script:TmpTools } | Should -Not -Throw
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
        Mock Register-ArgumentCompleter { }
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
}
