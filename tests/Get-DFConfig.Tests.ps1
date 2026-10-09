BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Get-DFConfig' {
    AfterEach { Remove-Variable DFConfig -Scope Global -ErrorAction Ignore }

    It 'returns the configured value' {
        $Global:DFConfig = @{ ShimsPath = 'C:\shims' }
        Get-DFConfig ShimsPath | Should -Be 'C:\shims'
    }
    It 'returns the default when the key is missing, $DFConfig is unset, or $DFConfig is $null' {
        $Global:DFConfig = @{}
        Get-DFConfig ShimsPath -Default 'd' | Should -Be 'd'
        Remove-Variable DFConfig -Scope Global
        Get-DFConfig ShimsPath -Default 'd' | Should -Be 'd'
        $Global:DFConfig = $null
        Get-DFConfig ShimsPath -Default 'd' | Should -Be 'd'
    }
    It 'returns a configured $false rather than the default' {
        $Global:DFConfig = @{ SkipConflictCheck = $false }
        Get-DFConfig SkipConflictCheck -Default $true | Should -BeFalse
    }
    It 'reads a list setting as a flat list, so -in and -notin work on it' {
        $Global:DFConfig = @{ SkipTools = @('lsd') }
        $skip = @(Get-DFConfig SkipTools)
        $skip | Should -Be @('lsd')
        'lsd' -in $skip | Should -BeTrue
        $Global:DFConfig = @{ SkipTools = @('lsd', 'eza') }
        @(Get-DFConfig SkipTools).Count | Should -Be 2
    }
    It 'returns a hashtable setting whole' {
        $Global:DFConfig = @{ Defaults = @{ listing = 'eza' } }
        (Get-DFConfig Defaults)['listing'] | Should -Be 'eza'
    }
}

Describe 'Resolve-DFThemeFile' {
    BeforeAll {
        $script:bundled = Join-Path $TestDrive 'Tools' 'fzf'
        New-Item -ItemType Directory -Path $script:bundled -Force | Out-Null
        Set-Content (Join-Path $script:bundled 'shipped.json') '{}'
    }
    BeforeEach { $script:saved = $Env:XDG_CONFIG_HOME; $Env:XDG_CONFIG_HOME = Join-Path $TestDrive 'config' }
    AfterEach  { $Env:XDG_CONFIG_HOME = $script:saved }

    It 'finds a bundled theme' {
        Resolve-DFThemeFile -Tool fzf -Name shipped -BundledDir $script:bundled |
            Should -Be (Join-Path $script:bundled 'shipped.json')
    }
    It 'prefers a theme in $XDG_CONFIG_HOME\<tool>\themes over a bundled one' {
        $user = Join-Path $Env:XDG_CONFIG_HOME 'fzf' 'themes'
        New-Item -ItemType Directory -Path $user -Force | Out-Null
        Set-Content (Join-Path $user 'shipped.json') '{}'
        Resolve-DFThemeFile -Tool fzf -Name shipped -BundledDir $script:bundled |
            Should -Be (Join-Path $user 'shipped.json')
    }
    It 'accepts an existing absolute path, and returns $null for anything it cannot find' {
        $abs = Join-Path $TestDrive 'mine.json'; Set-Content $abs '{}'
        Resolve-DFThemeFile -Tool fzf -Name $abs -BundledDir $script:bundled | Should -Be $abs
        Resolve-DFThemeFile -Tool fzf -Name 'nope' -BundledDir $script:bundled | Should -BeNullOrEmpty
        Resolve-DFThemeFile -Tool fzf -Name (Join-Path $TestDrive 'missing.json') -BundledDir $script:bundled | Should -BeNullOrEmpty
    }
}
