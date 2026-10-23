BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    function script:New-FontFile([string]$Name) {
        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path 'font' -NoNewline
        $path
    }
}

Describe 'Test-DFNerdFontName' {
    It 'matches <Name>' -ForEach @(
        @{ Name = 'JetBrainsMono Nerd Font Regular (TrueType)' }
        @{ Name = 'JetBrainsMonoNerdFont-Regular (TrueType)' }
        @{ Name = 'CaskaydiaCove NF (TrueType)' }
        @{ Name = 'Hack NFM Bold (TrueType)' }
        @{ Name = 'Hack NFP (OpenType)' }
    ) {
        Test-DFNerdFontName -Name $Name | Should -BeTrue
    }
    It 'does not match <Name>' -ForEach @(
        @{ Name = 'Cascadia Code (TrueType)' }
        @{ Name = 'Arial (TrueType)' }
        @{ Name = 'Segoe UI Symbol (TrueType)' }
    ) {
        Test-DFNerdFontName -Name $Name | Should -BeFalse
    }
}

Describe 'ConvertTo-DFFontFaceName' {
    It 'turns <Name> into <Face>' -ForEach @(
        @{ Name = 'Hack Nerd Font Regular (TrueType)'; Face = 'Hack Nerd Font' }
        @{ Name = 'JetBrainsMonoNerdFont-BoldItalic (TrueType)'; Face = 'JetBrainsMono Nerd Font' }
        @{ Name = 'CaskaydiaMonoNerdFontMono-Regular.ttf'; Face = 'CaskaydiaMono Nerd Font Mono' }
        @{ Name = 'CaskaydiaCove NF (TrueType)'; Face = 'CaskaydiaCove NF' }
    ) {
        ConvertTo-DFFontFaceName -Name $Name | Should -BeExactly $Face
    }
}

Describe 'Get-DFNerdFontFace' {
    It 'lists the faces of matching fonts whose file exists' {
        $file = New-FontFile 'HackNerdFont-Regular.ttf'
        Mock Get-DFFontRegistryEntry {
            [pscustomobject]@{ Name = 'Hack Nerd Font Regular (TrueType)'; Path = $file }
            [pscustomobject]@{ Name = 'Hack Nerd Font Bold (TrueType)'; Path = $file }
            [pscustomobject]@{ Name = 'Arial (TrueType)'; Path = $file }
        }
        @(Get-DFNerdFontFace) | Should -Be @('Hack Nerd Font')
    }
    It 'ignores a matching font whose file is gone' {
        Mock Get-DFFontRegistryEntry { [pscustomobject]@{ Name = 'Hack Nerd Font Regular (TrueType)'; Path = (Join-Path $TestDrive 'gone.ttf') } }
        @(Get-DFNerdFontFace).Count | Should -Be 0
    }
}

Describe 'Test-DFIconsOn' {
    BeforeEach { Reset-DFIconsOn; Set-DFTestConfig $null }
    AfterEach { Set-DFTestConfig $null; Reset-DFTestSession }

    It 'is on when NerdFont is $true, with no Nerd Font installed' {
        Mock Get-DFNerdFontFace { }
        Set-DFTestConfig @{ NerdFont = $true }
        Test-DFIconsOn | Should -BeTrue
    }
    It 'is off when NerdFont is $false, with a Nerd Font installed' {
        Mock Get-DFNerdFontFace { 'Hack Nerd Font' }
        Set-DFTestConfig @{ NerdFont = $false }
        Test-DFIconsOn | Should -BeFalse
    }
    It 'follows detection when NerdFont is unset' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontFace { }
        Test-DFIconsOn | Should -BeFalse
        Reset-DFIconsOn
        Mock Get-DFNerdFontFace { 'Hack Nerd Font' }
        Test-DFIconsOn | Should -BeTrue
    }
    It 'detects once per session' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontFace { 'Hack Nerd Font' }
        Test-DFIconsOn | Out-Null
        Test-DFIconsOn | Out-Null
        Should -Invoke Get-DFNerdFontFace -Times 1 -Exactly
    }
    It 'is a known config key' {
        $script:DFConfigKeys.Contains('NerdFont') | Should -BeTrue
    }
}

Describe 'Get-DFNerdFontChange' {
    BeforeEach { Set-DFTestXdg; Reset-DFIconsOn; Set-DFTestConfig $null }
    AfterEach { Restore-DFTestXdg; Reset-DFTestSession }

    It 'records a baseline silently the first time' {
        Mock Get-DFNerdFontFace { 'Hack Nerd Font' }
        $change = Get-DFNerdFontChange
        $change.Present | Should -BeTrue
        $change.NewlyPresent | Should -BeFalse
        Test-Path (Join-Path $Env:XDG_STATE_HOME 'dotforge' 'nerd-font.json') | Should -BeTrue
    }
    It 'reports a font that appeared since the last load, once' {
        Mock Get-DFNerdFontFace { }
        (Get-DFNerdFontChange).Present | Should -BeFalse
        Reset-DFIconsOn
        Mock Get-DFNerdFontFace { 'Hack Nerd Font' }
        $change = Get-DFNerdFontChange
        $change.NewlyPresent | Should -BeTrue
        @($change.Faces) | Should -Be @('Hack Nerd Font')
        (Get-DFNerdFontChange).NewlyPresent | Should -BeFalse
    }
}

Describe 'a tool that is only icons (nerdFont: required)' {
    BeforeAll {
        $script:IconTools = Join-Path $TestDrive 'icon-tools'
        New-Item -ItemType Directory $script:IconTools -Force | Out-Null
        '{ "name": "iconly", "type": "module", "executable": "IconlyModule", "nerdFont": "required" }' | Set-Content (Join-Path $script:IconTools 'iconly.json')
        '$global:DFTestIconlyRan = $true' | Set-Content (Join-Path $script:IconTools 'iconly.ps1')
    }
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession
        Mock Test-DFToolAvailable { $true }
        Mock Start-DFModulePrewarm { $null }
        Remove-Variable DFTestIconlyRan -Scope Global -ErrorAction Ignore
    }
    AfterEach { Restore-DFTestXdg; Reset-DFTestSession; Remove-Variable DFTestIconlyRan -Scope Global -ErrorAction Ignore }

    It 'is neither prewarmed nor activated while icons are off, and says why' {
        Mock Test-DFIconsOn { $false }
        Register-DFTool -Name 'iconly' -ToolsPath $script:IconTools
        $status = $script:DFSessionStatus['iconly']
        $status.State | Should -Be 'Excluded'
        $status.Detail | Should -Be 'needs a Nerd Font (icons are off; see NerdFont)'
        $global:DFTestIconlyRan | Should -BeNullOrEmpty
        Should -Invoke Start-DFModulePrewarm -Times 0
    }

    It 'loads as usual while icons are on' {
        Mock Test-DFIconsOn { $true }
        Register-DFTool -Name 'iconly' -ToolsPath $script:IconTools
        $script:DFSessionStatus['iconly'].State | Should -Be 'Active'
        $global:DFTestIconlyRan | Should -BeTrue
    }

    It 'rejects any value but "required"' {
        (Test-DFToolSchema ('{ "name": "x", "executable": "x.exe", "nerdFont": "yes" }' | ConvertFrom-Json)).Errors -join ' ' | Should -Match 'nerdFont'
        (Test-DFToolSchema ('{ "name": "x", "executable": "x.exe", "nerdFont": "required" }' | ConvertFrom-Json)).Valid | Should -BeTrue
    }

    It 'normalizes nerdFont to $null when absent' {
        (ConvertTo-DFToolRecord ('{ "name": "x", "executable": "x.exe" }' | ConvertFrom-Json)).nerdFont | Should -BeNullOrEmpty
        (ConvertTo-DFToolRecord ('{ "name": "x", "executable": "x.exe", "nerdFont": "required" }' | ConvertFrom-Json)).nerdFont | Should -Be 'required'
    }
}

Describe 'Write-DFNerdFontNotice' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFIconsOn; Set-DFTestConfig $null
        Mock Write-Host { }
    }
    AfterEach { Restore-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null }

    It 'says why icons are off when a tool left its icons out' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontFace { }
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $false; Faces = @(); NewlyPresent = $false } }
        Test-DFIconsOn | Out-Null
        Write-DFNerdFontNotice -WarningVariable w 3>$null
        "$w" | Should -BeExactly 'DotForge: No Nerd Font installed, so icons are off. Run Install-DFNerdFont, or set NerdFont = $true if your terminal already has one.'
    }
    It 'stays quiet when no tool this load draws icons' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $false; Faces = @(); NewlyPresent = $false } }
        Write-DFNerdFontNotice -WarningVariable w 3>$null
        "$w" | Should -BeNullOrEmpty
    }
    It 'names a text font, not the symbols-only one, in the one-time note' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $true; Faces = @('Symbols Nerd Font Mono', 'Hack Nerd Font Mono', 'Hack Nerd Font'); NewlyPresent = $true } }
        Write-DFNerdFontNotice 3>$null
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'DotForge: Nerd Font installed: Hack Nerd Font. Select it as your terminal''s font to see icons.' }
    }
    It 'stays quiet when NerdFont is set either way' -ForEach @(@{ Value = $true }, @{ Value = $false }) {
        Set-DFTestConfig @{ NerdFont = $Value }
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $false; Faces = @(); NewlyPresent = $false } }
        Write-DFNerdFontNotice -WarningVariable w 3>$null
        "$w" | Should -BeNullOrEmpty
    }
    It 'names a newly installed Nerd Font once' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $true; Faces = @('Hack Nerd Font'); NewlyPresent = $true } }
        Write-DFNerdFontNotice 3>$null
        Write-DFNerdFontNotice 3>$null
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'DotForge: Nerd Font installed: Hack Nerd Font. Select it as your terminal''s font to see icons.' }
    }
    It 'runs once per session from Write-DFSessionNotice' -Skip:(-not $IsWindows) {
        Mock Get-DFNerdFontFace { }
        Mock Get-DFNerdFontChange { [pscustomobject]@{ Present = $false; Faces = @(); NewlyPresent = $false } }
        Test-DFIconsOn | Out-Null
        Write-DFSessionNotice -WarningVariable w1 3>$null
        Write-DFSessionNotice -WarningVariable w2 3>$null
        "$w1" | Should -Match 'No Nerd Font installed'
        "$w2" | Should -BeNullOrEmpty
    }
}

Describe 'the font installer tools' {
    It '+fonts names the installers: <Name>' -ForEach @(@{ Name = 'NerdFonts' }, @{ Name = 'GoogleFonts' }, @{ Name = 'fontget' }, @{ Name = 'gfcli' }) {
        (Get-DFGroupDb)['fonts'].tools | Should -Contain $Name
        $record = Get-DFTestToolRecord $Name
        $record.roles.PSObject.Properties.Name | Should -Contain 'font-installer'
        (Test-DFToolSchema (Get-Content (Join-Path $PSScriptRoot '..' 'Tools' "$Name.json") -Raw | ConvertFrom-Json)).Valid | Should -BeTrue
    }
    It 'font-installer is a category role' {
        (Get-DFRoleDb)['font-installer'].kind | Should -Be 'category'
    }
    It 'FontGet warns that its per-user installs are lost on reboot' {
        (Get-DFTestToolRecord 'fontget').setup.notes.text | Should -Match 'FontGet/issues/9'
    }
}
