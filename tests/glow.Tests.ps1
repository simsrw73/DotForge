BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    $script:GlowJson  = Get-Content "$PSScriptRoot/../Tools/glow.json" -Raw | ConvertFrom-Json
    $script:BundleDir = Join-Path $PSScriptRoot '../Tools/glow'
}

Describe 'Tools/glow.json' {
    BeforeEach { Reset-DFTestSession }
    It 'points glow at its XDG config folder through GLOW_CONFIG_HOME' {
        # glow 3 reads <GLOW_CONFIG_HOME>/glow.yml; its --config flag has no effect
        # (verified glow 3.0.0; see docs/external-dependencies.md).
        $script:GlowJson.xdg.method | Should -Be 'env'
        $script:GlowJson.xdg.vars.GLOW_CONFIG_HOME | Should -Be '${XDG_CONFIG_HOME}/glow'
        $script:GlowJson.PSObject.Properties['settings'] | Should -BeNullOrEmpty
    }

    It 'declares its style files and the -s wrapper' {
        $script:GlowJson.theme.files | Should -Be 'glow'
        $script:GlowJson.theme.fallback | Should -Be 'auto'
        $script:GlowJson.wrapper.args | Should -Be @('-s', '{theme}')
        $script:GlowJson.PSObject.Properties['settings'] | Should -BeNullOrEmpty
    }

    It 'defaults to a theme bundled in Tools/glow' {
        $name = $script:GlowJson.theme.default
        Test-Path (Join-Path $script:BundleDir "$name.json") | Should -BeTrue
    }

    It 'ships the bundled theme as a parsable glamour style document' {
        $name  = $script:GlowJson.theme.default
        $style = Get-Content (Join-Path $script:BundleDir "$name.json") -Raw | ConvertFrom-Json
        $style.document | Should -Not -BeNullOrEmpty
        $style.h1       | Should -Not -BeNullOrEmpty
    }
}

Describe 'glow tool sidecar' -Skip:(-not (Get-Command glow.exe -ErrorAction Ignore)) {
    BeforeEach { Reset-DFTestSession;
        $script:DFToolDb        = $null
        $script:DFToolAvailability = @{}
        Set-DFTestXdg
        $script:SavedConfigDir  = $Env:GLOW_CONFIG_DIR

        $Env:GLOW_CONFIG_DIR    = $null

        # TestDrive persists for the whole file's run, not per-It: without this,
        # a theme file written to the XDG user dir by one test (e.g. the "prefers
        # a theme from the XDG user dir" test below) leaks into every later test
        # that reuses this same $Env:XDG_CONFIG_HOME path.
        Remove-Item $Env:XDG_CONFIG_HOME -Recurse -Force -ErrorAction Ignore

        # Do not inherit $DFConfig from whichever test file ran before this one
        # (tests/Get-DFCommandConflict.Tests.ps1 leaves it set to $null).
        Set-DFTestConfig $null

        # Point at the real Tools directory
        $script:RealTools = Join-Path $PSScriptRoot '../Tools'
    }

    AfterEach {
        $Env:GLOW_CONFIG_DIR = $script:SavedConfigDir
        $script:DFToolDb     = $null

        Set-DFTestConfig $null
        Remove-DFTestGlobal -Function 'glow', 'Read-MarkdownFile'
        Restore-DFTestXdg
    }

    It 'wraps glow as a global function' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        Test-Path 'function:global:glow' | Should -BeTrue
    }

    It 'resolves the bundled theme by default' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        # The sidecar builds this from its own $PSScriptRoot, which is already
        # canonical — resolve the test's ../Tools form so the comparison matches.
        $expected = (Resolve-Path (Join-Path $script:RealTools 'glow' 'catppuccin-mocha.json')).Path
        (Get-DFSessionThemeValue -Name glow) | Should -Be $expected
    }

    It 'creates the XDG config directory' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        Test-Path (Join-Path $Env:XDG_CONFIG_HOME 'glow') | Should -BeTrue
    }

    It 'sets GLOW_CONFIG_HOME, and the wrapper and picker pass no --config' {
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $Env:GLOW_CONFIG_HOME | Should -Be (ConvertTo-DFPath (Join-Path $Env:XDG_CONFIG_HOME 'glow'))
        $Env:GLOW_CONFIG_DIR | Should -BeNullOrEmpty
        ${function:global:glow}.ToString() | Should -Not -Match '--config'
        ${function:global:Read-MarkdownFile}.ToString() | Should -Not -Match '--config'
    }

    It 'prefers a theme from the XDG user dir over the bundled copy' {
        $userDir = Join-Path $Env:XDG_CONFIG_HOME 'glow' 'themes'
        New-Item -ItemType Directory -Force -Path $userDir | Out-Null
        $userTheme = Join-Path $userDir 'catppuccin-mocha.json'
        '{ "document": {}, "h1": {} }' | Set-Content $userTheme

        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        (Get-DFSessionThemeValue -Name glow) | Should -Be $userTheme
    }

    It 'passes a glow built-in style name through unchanged' {
        Set-DFTestConfig @{ GlowTheme = 'dracula' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        (Get-DFSessionThemeValue -Name glow) | Should -Be 'dracula'
    }

    It 'follows the shared $DFConfig[Theme] key (catppuccin-mocha -> bundled mocha)' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        $expected = (Resolve-Path (Join-Path $script:RealTools 'glow' 'catppuccin-mocha.json')).Path
        (Get-DFSessionThemeValue -Name glow) | Should -Be $expected
    }

    It 'lets GlowTheme override the shared Theme key' {
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha'; GlowTheme = 'dracula' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        (Get-DFSessionThemeValue -Name glow) | Should -Be 'dracula'
    }

    It 'no longer treats the bare "catppuccin" alias as the mocha family (retired)' {
        Set-DFTestConfig @{ Theme = 'catppuccin' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        # Old code mapped 'catppuccin' -> catppuccin-mocha.json; new code passes it
        # through and glow, not recognizing it, falls back to 'auto'.
        (Get-DFSessionThemeValue -Name glow) | Should -Be 'auto'
    }

    It 'falls back to auto and warns for an unknown theme' {
        # A -s path glow cannot load makes it exit 1, so an unresolved name must
        # never reach the flag.
        Set-DFTestConfig @{ GlowTheme = 'no-such-theme' }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools -WarningVariable warnings -WarningAction SilentlyContinue
        (Get-DFSessionThemeValue -Name glow) | Should -Be 'auto'
        $warnings -join "`n" | Should -Match "glow theme 'no-such-theme' not recognized — falling back to 'auto'"
    }

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        Set-DFTestConfig $null
        { Register-DFTool -Name 'glow' -ToolsPath $script:RealTools } | Should -Not -Throw
        (Get-DFSessionThemeValue -Name glow) | Should -Not -BeNullOrEmpty
    }

    It 'accepts a rooted path to an existing style file' {
        $custom = Join-Path $TestDrive 'my-style.json'
        '{ "document": {} }' | Set-Content $custom
        Set-DFTestConfig @{ GlowTheme = $custom }
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        (Get-DFSessionThemeValue -Name glow) | Should -Be $custom
    }

    It 'renders piped markdown without hanging' {
        # Regression: a wrapper body of `& glow.exe @args` swallows the pipeline,
        # leaving glow.exe blocked on the inherited console stdin. The companion
        # forwards $input; the job checks that pattern with findstr.exe, which
        # blocks the same way: running the real glow would create
        # %LOCALAPPDATA%\glow, which no environment variable can redirect.
        Register-DFTool -Name 'glow' -ToolsPath $script:RealTools
        ${function:global:glow}.ToString() | Should -Match ([regex]::Escape('$input | & $_dfExe @declared'))
        $job = Start-Job -ScriptBlock {
            Set-Item -Path 'function:global:glow' -Value ([scriptblock]::Create(
                "if (`$MyInvocation.ExpectingInput) { `$input | & findstr.exe . }" +
                " else { & findstr.exe . }"))
            ('# Piped' | glow) -join ''
        }

        try {
            Wait-Job $job -Timeout 60 | Should -Not -BeNullOrEmpty -Because 'the wrapper must forward stdin instead of blocking'
            (Receive-Job $job) -join '' | Should -Match 'Piped'
        } finally {
            Stop-Job $job -ErrorAction Ignore
            Remove-Job $job -Force -ErrorAction Ignore
        }
    }
}
