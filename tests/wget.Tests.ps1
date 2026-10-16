BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:WgetJson = Get-Content "$PSScriptRoot/../Tools/wget.json" -Raw | ConvertFrom-Json
}

Describe 'Tools/wget.json' {
    It 'seeds its bundled wgetrc to the path WGETRC names' {
        # wget refuses to run at all when WGETRC names a missing file.
        $seed = $script:WgetJson.setup.seed.PSObject.Properties
        @($seed).Count | Should -Be 1
        $seed.Name | Should -Be $script:WgetJson.xdg.vars.WGETRC
        Test-Path (Join-Path "$PSScriptRoot/../Tools" $seed.Value) -PathType Leaf | Should -BeTrue
    }

    It 'ships a wgetrc that sets nothing' {
        $file = Join-Path "$PSScriptRoot/../Tools" $script:WgetJson.setup.seed.PSObject.Properties.Value
        Get-Content $file | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Should -BeNullOrEmpty
    }
}

Describe 'wget registration' -Skip:(-not (Get-Command wget.exe -ErrorAction Ignore)) {
    BeforeEach {
        Reset-DFTestSession
        $script:DFToolDb           = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg
        # A fresh machine: no config, and no record that setup already ran.
        Remove-Item $Env:XDG_CONFIG_HOME, $Env:XDG_STATE_HOME -Recurse -Force -ErrorAction Ignore
        # A value inherited from the developer's own DotForge shell would be kept (Set-DFEnv).
        $script:SavedWgetrc = $Env:WGETRC
        $Env:WGETRC         = $null
        Set-DFTestConfig $null
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:WGETRC      = $script:SavedWgetrc
        $script:DFToolDb = $null
        Set-DFTestConfig $null
        Restore-DFTestXdg
    }

    It 'seeds wgetrc on first registration, and wget runs' {
        Register-DFTool -Name 'wget' -ToolsPath $script:RealTools
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'wget' 'wgetrc'
        Test-Path $cfg | Should -BeTrue
        $Env:WGETRC | Should -Be (ConvertTo-DFPath $cfg)

        wget.exe --version *> $null
        $LASTEXITCODE | Should -Be 0
    }

    It 'does not overwrite an existing wgetrc' {
        $cfg = Join-Path $Env:XDG_CONFIG_HOME 'wget' 'wgetrc'
        New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
        'tries = 3' | Set-Content $cfg

        Register-DFTool -Name 'wget' -ToolsPath $script:RealTools
        Get-Content $cfg -Raw | Should -Match '^tries = 3'
    }
}
