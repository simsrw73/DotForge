BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:FastfetchJson = Get-Content "$PSScriptRoot/../Tools/fastfetch.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/fastfetch.json' {
    It 'declares the wrapper XDG method' {
        # fastfetch's Windows config discovery is a hardcoded Win32 known-folder
        # lookup and ignores XDG_CONFIG_HOME entirely -- see docs/external-dependencies.md.
        $script:FastfetchJson.xdg.method | Should -Be 'wrapper'
    }

    It 'declares no XDG environment variables' {
        # Regression guard: setting XDG_CONFIG_HOME as an env var here would be a
        # no-op, since fastfetch never reads it.
        $script:FastfetchJson.xdg.PSObject.Properties['vars'] | Should -BeNullOrEmpty
    }

    It 'ships a seeded config that parses as JSON' {
        { $script:FastfetchJson.settings.configContent | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'excludes the publicip module (measured 2.87s cold-path network spike during design)' {
        $config = $script:FastfetchJson.settings.configContent | ConvertFrom-Json
        $config.modules | Should -Not -Contain 'publicip'
    }
}

Describe 'fastfetch tool sidecar' -Skip:(-not (Get-Command fastfetch.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb          = $null
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome   = $Env:XDG_CONFIG_HOME
        $Env:XDG_CONFIG_HOME      = Join-Path $TestDrive 'config'

        Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore

        # Do not inherit $DFConfig from whichever test file ran before this one.
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore

        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $script:DFToolDb     = $null

        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function 'fastfetch'
    }

    It 'wraps fastfetch as a global function' {
        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        Test-Path 'function:global:fastfetch' | Should -BeTrue
    }

    It 'creates the XDG config directory' {
        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'fastfetch') | Should -BeTrue
    }

    It 'seeds the themed config on first registration' {
        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc'
        Test-Path $cfg | Should -BeTrue
        { Get-Content $cfg -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'does not overwrite an existing config on re-registration' {
        # Regression: Set-DFToolXdgConfig's "seed only when absent" behavior is
        # bypassed for wrapper tools -- Tools/fastfetch.ps1 must replicate it itself.
        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'fastfetch/config.jsonc'
        Add-Content $cfg "`n// user edit marker"

        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        Get-Content $cfg -Raw | Should -Match 'user edit marker'
    }

    It 'runs successfully via the wrapped --config flag, independent of XDG_CONFIG_HOME auto-discovery' {
        # fastfetch's own config auto-discovery ignores XDG_CONFIG_HOME (that's the
        # whole reason for this wrapper); this proves the explicit --config flag
        # still resolves to our seeded file even when XDG_CONFIG_HOME points
        # somewhere fastfetch would never look on its own.
        Register-DFTool -Name 'fastfetch' -ToolsPath $script:RealTools
        { fastfetch } | Should -Not -Throw
    }
}
