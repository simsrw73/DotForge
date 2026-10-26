BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Tools/vivid.json' {
    BeforeEach { Reset-DFTestSession }
    BeforeAll {
        $script:VividJson = Get-Content "$PSScriptRoot/../Tools/vivid.json" -Raw | ConvertFrom-Json
    }

    It 'declares the default XDG method' {
        $script:VividJson.xdg.method | Should -Be 'default'
    }

    It 'declares scoop and winget package ids, and no choco' {
        $script:VividJson.packages.scoop  | Should -Be 'vivid'
        $script:VividJson.packages.winget | Should -Be 'sharkdp.vivid'
        $script:VividJson.packages.PSObject.Properties.Name | Should -Not -Contain 'choco'
    }

    It 'defaults the theme setting to catppuccin-mocha' {
        $script:VividJson.theme.default | Should -Be 'catppuccin-mocha'
    }

    It 'seeds a trimmed filetypes database, with vivid''s own location as its native one' {
        $script:VividJson.setup.seed.'${XDG_CONFIG_HOME}/vivid/filetypes.yml' | Should -Be 'vivid/filetypes.yml'
        @($script:VividJson.xdg.native.'${XDG_CONFIG_HOME}/vivid/filetypes.yml').Count | Should -BeGreaterThan 0
        Test-Path "$PSScriptRoot/../Tools/vivid/filetypes.yml" | Should -BeTrue
    }

    It 'declares a custom picker' {
        $script:VividJson.picker | Should -Be 'custom'
    }
}

Describe 'vivid tool sidecar' -Skip:(-not (Get-Command vivid.exe -ErrorAction Ignore)) {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb       = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg



        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
        # TestDrive lasts for the whole Describe: seed vivid's database afresh in every test.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'vivid') -Recurse -Force -ErrorAction Ignore

        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {

        $script:DFToolDb     = $null

        [System.Environment]::SetEnvironmentVariable('LS_COLORS', $null, 'Process')
        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'Invoke-DFApplyLSColorsTheme', 'Select-LSColorsTheme'
        Remove-Alias fls -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'sets LS_COLORS to vivid catppuccin-mocha output by default' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'registers Invoke-DFApplyLSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Invoke-DFApplyLSColorsTheme' | Should -BeTrue
    }

    It 'registers Select-LSColorsTheme as a global function' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path 'function:global:Select-LSColorsTheme' | Should -BeTrue
    }

    It 'registers fls as an alias for Select-LSColorsTheme' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Get-Alias fls -ErrorAction Ignore | Should -Not -BeNullOrEmpty
    }

    It 'generates from the seeded database: under 8,191 characters with the default theme' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'vivid' 'filetypes.yml') | Should -BeTrue
        $Env:LS_COLORS.Length | Should -BeLessThan 8191
        $Env:LS_COLORS | Should -Not -Match '\*\.nim='
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'falls back to vivid''s own database when the seeded one is gone' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'vivid' 'filetypes.yml')
        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha'
        $Env:LS_COLORS | Should -Match '\*\.nim='
    }

    It 'regenerates after the database changes' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8
        $database = Get-Item (Join-Path $Env:XDG_CONFIG_HOME 'vivid' 'filetypes.yml')
        $database.LastWriteTimeUtc = $database.LastWriteTimeUtc.AddMinutes(1)

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha'

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
    }

    It 'caches the generated value and reuses it for a matching theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha'

        $Env:LS_COLORS | Should -Be 'SENTINEL-CACHED-VALUE'
    }

    It 'regenerates when the theme name differs from the cached key' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-latte'

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
        $Env:LS_COLORS | Should -Not -BeNullOrEmpty
    }

    It 'always regenerates when -Force is passed, even on a matching cache key' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.txt'
        Set-Content -Path $cacheFile -Value 'SENTINEL-CACHED-VALUE' -Encoding UTF8

        Invoke-DFApplyLSColorsTheme -Name 'catppuccin-mocha' -Force

        $Env:LS_COLORS | Should -Not -Be 'SENTINEL-CACHED-VALUE'
        $Env:LS_COLORS | Should -Match 'di=0;38;2;137;180;250'
    }

    It 'warns and leaves LS_COLORS unchanged for an unrecognized theme name' {
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', 'PRE-EXISTING', 'Process')

        $warnings = Invoke-DFApplyLSColorsTheme -Name 'not-a-real-theme' 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $warnings | Where-Object { $_ -match "theme 'not-a-real-theme'" } | Should -Not -BeNullOrEmpty
        $Env:LS_COLORS | Should -Be 'PRE-EXISTING'
    }

    It 'follows the shared $DFConfig[Theme] key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -BeLike 'catppuccin-latte|*'
    }

    It 'lets VividTheme override the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte'; VividTheme = 'catppuccin-mocha' }
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $keyFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'ls-colors.key'
        (Get-Content $keyFile -Raw).Trim() | Should -BeLike 'catppuccin-mocha|*'
    }

    It 'keeps an LS_COLORS set outside DotForge when VividTheme is not set' {
        [System.Environment]::SetEnvironmentVariable('LS_COLORS', 'di=01;34', 'Process')
        Register-DFTool -Name 'vivid' -ToolsPath $script:RealTools
        $Env:LS_COLORS | Should -Be 'di=01;34'
    }
}
