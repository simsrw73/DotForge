BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
    $script:Bundled = [System.IO.Path]::GetFullPath((Join-Path $script:Tools 'oh-my-posh'))
}

Describe 'Resolve-DFOhMyPoshConfig' {
    BeforeAll { . (Join-Path $script:Tools 'oh-my-posh.ps1') }
    BeforeEach {
        Set-DFTestXdg
        $script:SavedTheme = $Env:POSH_THEME; $script:SavedThemes = $Env:POSH_THEMES_PATH
        Remove-Item Env:POSH_THEME, Env:POSH_THEMES_PATH -ErrorAction Ignore
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh') -Recurse -Force -ErrorAction Ignore
        # Icons on unless a test says otherwise, so the result doesn't depend on this machine's fonts.
        Mock Test-DFIconsOn { $true }
    }
    AfterEach {
        if ($null -ne $script:SavedTheme) { $Env:POSH_THEME = $script:SavedTheme } else { Remove-Item Env:POSH_THEME -ErrorAction Ignore }
        if ($null -ne $script:SavedThemes) { $Env:POSH_THEMES_PATH = $script:SavedThemes } else { Remove-Item Env:POSH_THEMES_PATH -ErrorAction Ignore }
        Restore-DFTestXdg
    }

    It 'uses the bundled theme when you have no config' {
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $script:Bundled 'catppuccin_latte.omp.json')
    }
    It 'uses the plain bundled theme while icons are off' {
        Mock Test-DFIconsOn { $false }
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $script:Bundled 'plain' 'catppuccin_latte.omp.json')
    }
    It 'uses the icon bundled theme while icons are on' {
        Mock Test-DFIconsOn { $true }
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $script:Bundled 'catppuccin_latte.omp.json')
    }
    It 'prefers a same-named theme in POSH_THEMES_PATH over the bundled one' {
        $themes = Join-Path $TestDrive 'themes'; New-Item -ItemType Directory $themes -Force | Out-Null
        Set-Content (Join-Path $themes 'catppuccin_latte.omp.json') '{}'
        $Env:POSH_THEMES_PATH = $themes
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $themes 'catppuccin_latte.omp.json')
    }
    It 'prefers your one config in $XDG_CONFIG_HOME\oh-my-posh' {
        $dir = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh'; New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'mine.omp.json') '{}'
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $dir 'mine.omp.json')
    }
    It 'prefers your POSH_THEME above everything' {
        $mine = Join-Path $TestDrive 'mine.omp.json'; Set-Content $mine '{}'
        $Env:POSH_THEME = $mine
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be $mine
    }
    It 'ignores a POSH_THEME pointing at a bundled theme (a nested shell inherited it)' {
        $Env:POSH_THEME = Join-Path $script:Bundled 'catppuccin_mocha.omp.json'
        Resolve-DFOhMyPoshConfig -Native 'catppuccin_latte' -Bundled $script:Bundled | Should -Be (Join-Path $script:Bundled 'catppuccin_latte.omp.json')
    }
}

Describe 'oh-my-posh follows Theme in a session' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh') -Recurse -Force -ErrorAction Ignore
        $script:SavedTheme = $Env:POSH_THEME
        Remove-Item Env:POSH_THEME -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Get-Module { } -ParameterFilter { $Name -eq 'posh-git' -or $ListAvailable }
        $global:OmpConfigs = @()
        function global:oh-my-posh { $i = [array]::IndexOf($args, '--config'); if ($i -ge 0) { $global:OmpConfigs += $args[$i + 1] }; '$null' }
    }
    AfterEach {
        if ($null -ne $script:SavedTheme) { $Env:POSH_THEME = $script:SavedTheme } else { Remove-Item Env:POSH_THEME -ErrorAction Ignore }
        Remove-Item Env:POSH_THEMES_PATH -ErrorAction Ignore
        Remove-Variable OmpConfigs -Scope Global -ErrorAction Ignore
        Remove-DFTestGlobal -Function oh-my-posh, Select-PoshTheme, Invoke-DFApplyOhMyPoshTheme -Alias fpot
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'starts with the bundled theme matching Theme' {
        Start-DFSession -Config @{ Tools = @('oh-my-posh'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        $global:OmpConfigs[-1] | Should -Be (Join-Path $script:Bundled 'catppuccin_latte.omp.json')
    }
    It 'switches with Set-DFToolTheme, even over your own config' {
        $dir = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh'; New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'mine.omp.json') '{}'
        Start-DFSession -Config @{ Tools = @('oh-my-posh') } -ToolsPath $script:Tools 3>$null
        $global:OmpConfigs[-1] | Should -Be (Join-Path $dir 'mine.omp.json')
        $null = Set-DFToolTheme -Name oh-my-posh -Theme catppuccin-frappe
        $global:OmpConfigs[-1] | Should -Be (Join-Path $script:Bundled 'catppuccin_frappe.omp.json')
    }
    It 'knows the OhMyPoshTheme setting' {
        $script:DFConfigKeys.Keys | Should -Contain 'OhMyPoshTheme'
    }
}

Describe 'Set-DFToolTheme when the apply function is not defined this session' {
    It 'says so instead of failing' {
        Reset-DFTestSession
        $tool = ConvertTo-DFToolRecord ('{ "name": "x", "executable": "x.exe", "theme": { "key": "XTheme", "default": "a", "apply": "Invoke-NotDefinedApply" } }' | ConvertFrom-Json)
        $script:DFSessionToolDb['x'] = $tool
        Mock Test-DFToolActive { $true }
        Set-DFToolTheme -Name x -Theme a -ErrorAction SilentlyContinue -ErrorVariable e | Out-Null
        "$e" | Should -Match "isn't applied in this session"
        Reset-DFTestSession
    }
}

Describe 'the plain bundled themes' {
    It 'exist for every bundled theme and draw no Nerd Font glyph: <Name>' -ForEach @(
        @{ Name = 'catppuccin_mocha' }, @{ Name = 'catppuccin_macchiato' }, @{ Name = 'catppuccin_frappe' }, @{ Name = 'catppuccin_latte' }
    ) {
        $file = Join-Path $script:Bundled 'plain' "$Name.omp.json"
        $text = Get-Content -LiteralPath $file -Raw
        { $text | ConvertFrom-Json } | Should -Not -Throw
        # The JSON may hold a glyph as itself or as a \uXXXX escape: check both.
        $text | Should -Not -Match '[\uE000-\uF8FF]'
        $text | Should -Not -Match '\\u[eEfF][0-8a-fA-F][0-9a-fA-F]{2}'
    }
}
