BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFFzf.ps1"
    . "$PSScriptRoot/../Public/Invoke-DFPicker.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolSchema.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFTopoSort.ps1"
    . "$PSScriptRoot/../Private/Test-DFToolAvailable.ps1"
    . "$PSScriptRoot/../Public/Get-DFTool.ps1"
    . "$PSScriptRoot/../Public/Find-DFTool.ps1"
    # Register-DFTool calls Get-DFCommandConflict for its shadowed-command warning.
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"

    $script:GlowJson  = Get-Content "$PSScriptRoot/../Tools/glow.json" -Raw | ConvertFrom-Json
    $script:BundleDir = Join-Path $PSScriptRoot '../Tools/glow'
}

Describe 'Tools/glow.json' {
    It 'declares the wrapper XDG method' {
        # glow is configured by CLI flags in Tools/glow.ps1, not by Register-DFTool.
        $script:GlowJson.xdg.method | Should -Be 'wrapper'
    }

    It 'declares no XDG environment variables' {
        # Regression: GLOW_CONFIG_DIR was set here and glow ignores it outright —
        # its config path comes from a Win32 known-folder lookup, not the environment.
        $script:GlowJson.xdg.PSObject.Properties['vars'] | Should -BeNullOrEmpty
    }

    It 'names a theme that Resolve-DFGlowStyle can resolve without the binary' {
        $name = $script:GlowJson.settings.theme
        Test-Path (Join-Path $script:BundleDir "$name.json") | Should -BeTrue
    }

    It 'ships the bundled theme as a parsable glamour style document' {
        $name  = $script:GlowJson.settings.theme
        $style = Get-Content (Join-Path $script:BundleDir "$name.json") -Raw | ConvertFrom-Json
        $style.document | Should -Not -BeNullOrEmpty
        $style.h1       | Should -Not -BeNullOrEmpty
    }
}

Describe 'glow tool sidecar' -Skip:(-not (Get-Command glow.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:DFToolDb        = $null
        $script:DFToolAvailability = @{}
        $script:SavedConfigHome = $Env:XDG_CONFIG_HOME
        $script:SavedConfigDir  = $Env:GLOW_CONFIG_DIR
        $Env:XDG_CONFIG_HOME    = Join-Path $TestDrive 'config'
        $Env:GLOW_CONFIG_DIR    = $null

        # TestDrive persists for the whole file's run, not per-It: without this,
        # a theme file written to the XDG user dir by one test (e.g. the "prefers
        # a theme from the XDG user dir" test below) leaks into every later test
        # that reuses this same $Env:XDG_CONFIG_HOME path.
        Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore

        # Do not inherit $DFConfig from whichever test file ran before this one
        # (tests/Get-DFCommandConflict.Tests.ps1 leaves it set to $null).
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:XDG_CONFIG_HOME = $script:SavedConfigHome
        $Env:GLOW_CONFIG_DIR = $script:SavedConfigDir
        $script:DFToolDb     = $null

        Remove-Variable DFConfig    -Scope Global -ErrorAction Ignore
        Remove-Variable DFGlowStyle -Scope Global -ErrorAction Ignore
        Remove-Item 'function:global:glow'                -ErrorAction Ignore
        Remove-Item 'function:global:Resolve-DFGlowStyle' -ErrorAction Ignore
    }

    It 'wraps glow as a global function' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        Test-Path 'function:global:glow' | Should -BeTrue
    }

    It 'registers Resolve-DFGlowStyle as a global function' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        Test-Path 'function:global:Resolve-DFGlowStyle' | Should -BeTrue
    }

    It 'resolves the bundled theme by default' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        # The sidecar builds this from its own $PSScriptRoot, which is already
        # canonical — resolve the test's ../Tools form so the comparison matches.
        $expected = (Resolve-Path (Join-Path $script:RealTools 'glow' 'catppuccin-mocha.json')).Path
        $global:DFGlowStyle | Should -Be $expected
    }

    It 'creates the XDG config directory' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'glow') | Should -BeTrue
    }

    It 'sets no GLOW_CONFIG_DIR environment variable' {
        # Regression: the env var never worked; the wrapper passes --config instead.
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $Env:GLOW_CONFIG_DIR | Should -BeNullOrEmpty
    }

    It 'prefers a theme from the XDG user dir over the bundled copy' {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'glow' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        $userTheme = Join-Path $userDir 'catppuccin-mocha.json'
        '{ "document": {}, "h1": {} }' | Set-Content $userTheme

        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $global:DFGlowStyle | Should -Be $userTheme
    }

    It 'passes a glow built-in style name through unchanged' {
        $Global:DFConfig = @{ GlowTheme = 'dracula' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $global:DFGlowStyle | Should -Be 'dracula'
    }

    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> bundled mocha)' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $expected = (Resolve-Path (Join-Path $script:RealTools 'glow' 'catppuccin-mocha.json')).Path
        $global:DFGlowStyle | Should -Be $expected
    }

    It 'lets GlowTheme override the shared Theme key' {
        $Global:DFConfig = @{ Theme = 'catppuccin-mocha'; GlowTheme = 'dracula' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $global:DFGlowStyle | Should -Be 'dracula'
    }

    It 'no longer treats the bare "catppuccin" alias as the mocha family (retired)' {
        $Global:DFConfig = @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        # Old code mapped 'catppuccin' -> catppuccin-mocha.json; new code passes it
        # through and glow, not recognizing it, falls back to 'auto'.
        $global:DFGlowStyle | Should -Be 'auto'
    }

    It 'falls back to auto and warns for an unknown theme' {
        # A -s path glow cannot load makes it exit 1, so an unresolved name must
        # never reach the flag.
        $Global:DFConfig = @{ GlowTheme = 'no-such-theme' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools -WarningVariable warnings -WarningAction SilentlyContinue
        $global:DFGlowStyle | Should -Be 'auto'
        $warnings -join "`n" | Should -Match "glow style 'no-such-theme' not found"
    }

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        $Global:DFConfig = $null
        { Register-DFTool -Name 'glow' -ToolsPath $script:RealTools } | Should -Not -Throw
        $global:DFGlowStyle | Should -Not -BeNullOrEmpty
    }

    It 'accepts a rooted path to an existing style file' {
        $custom = Join-Path $TestDrive 'my-style.json'
        '{ "document": {} }' | Set-Content $custom
        $Global:DFConfig = @{ GlowTheme = $custom }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $global:DFGlowStyle | Should -Be $custom
    }

    It 'renders piped markdown without hanging' {
        # Regression: a wrapper body of `& glow.exe @args` swallows the pipeline,
        # leaving glow.exe blocked on the inherited console stdin.
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $job = Start-Job -ScriptBlock {
            param($cfg, $style)
            Set-Item -Path 'function:global:glow' -Value ([scriptblock]::Create(
                "if (`$MyInvocation.ExpectingInput) { `$input | & glow.exe --config '$cfg' -s '$style' @args }" +
                " else { & glow.exe --config '$cfg' -s '$style' @args }"))
            ('# Piped' | glow -w 20) -join ''
        } -ArgumentList (Join-Path $Env:XDG_CONFIG_HOME 'glow/glow.yml'), $global:DFGlowStyle

        try {
            Wait-Job $job -Timeout 60 | Should -Not -BeNullOrEmpty -Because 'the wrapper must forward stdin instead of blocking'
            (Receive-Job $job) -join '' | Should -Match 'Piped'
        } finally {
            Stop-Job $job -ErrorAction Ignore
            Remove-Job $job -Force -ErrorAction Ignore
        }
    }
}
