BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:RipgrepJson = Get-Content "$PSScriptRoot/../Tools/ripgrep.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/ripgrep.json' {
    It 'seeds its bundled ripgreprc to the path RIPGREP_CONFIG_PATH names' {
        # rg prints an error on every search when RIPGREP_CONFIG_PATH names a missing file.
        $seed = $script:RipgrepJson.setup.seed.PSObject.Properties
        @($seed).Count | Should -Be 1
        $seed.Name | Should -Be $script:RipgrepJson.xdg.vars.RIPGREP_CONFIG_PATH
        Test-Path (Join-Path "$PSScriptRoot/../Tools" $seed.Value) -PathType Leaf | Should -BeTrue
    }

    It 'ships a ripgreprc of one flag per line' {
        $file  = Join-Path "$PSScriptRoot/../Tools" $script:RipgrepJson.setup.seed.PSObject.Properties.Value
        $flags = Get-Content $file | Where-Object { $_ -and $_ -notmatch '^\s*#' }
        $flags | Should -Contain '--smart-case'
        $flags | ForEach-Object { $_ | Should -Match '^--\S+$' }
    }
}

Describe 'ripgrep registration' -Skip:(-not (Get-Command rg.exe -ErrorAction Ignore)) {
    BeforeEach {
        Reset-DFTestSession
        $script:DFToolDb           = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg
        # A fresh machine: no config, and no record that setup already ran.
        Remove-Item $Env:XDG_CONFIG_HOME, $Env:XDG_STATE_HOME -Recurse -Force -ErrorAction Ignore
        # A value inherited from the developer's own DotForge shell would be kept (Set-DFEnv).
        $script:SavedConfigPath   = $Env:RIPGREP_CONFIG_PATH
        $Env:RIPGREP_CONFIG_PATH  = $null
        Set-DFTestConfig $null
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:RIPGREP_CONFIG_PATH = $script:SavedConfigPath
        $script:DFToolDb         = $null
        Set-DFTestConfig $null
        Restore-DFTestXdg
    }

    It 'seeds ripgreprc on first registration, and rg reads it without error' {
        Register-DFTool -Name 'ripgrep' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'ripgrep' 'ripgreprc'
        Test-Path $cfg | Should -BeTrue
        $Env:RIPGREP_CONFIG_PATH | Should -Be (ConvertTo-DFPath $cfg)

        $output = 'needle' | rg.exe needle 2>&1
        $output | Should -Not -Match 'failed to read'
    }

    It 'does not overwrite an existing ripgreprc' {
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'ripgrep' 'ripgreprc'
        New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
        '--case-sensitive' | Set-Content $cfg

        Register-DFTool -Name 'ripgrep' -ToolsPath $script:RealTools
        Get-Content $cfg -Raw | Should -Match '^--case-sensitive'
    }
}
