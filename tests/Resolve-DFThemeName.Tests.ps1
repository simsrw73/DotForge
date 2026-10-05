BeforeAll {
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
}

Describe 'Resolve-DFThemeName' {
    It 'translates a canonical family key to the tool dialect' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap $map | Should -Be 'catppuccin'
    }
    It 'matches the canonical key case-insensitively' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'Catppuccin-Mocha' -ThemeMap $map | Should -Be 'catppuccin'
    }
    It 'passes a name that is not a canonical key straight through' {
        $map = [pscustomobject]@{ 'catppuccin-mocha' = 'catppuccin' }
        Resolve-DFThemeName -Name 'dracula' -ThemeMap $map | Should -Be 'dracula'
    }
    It 'passes through when the map is $null (tool has no themeMap)' {
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap $null | Should -Be 'catppuccin-mocha'
    }
    It 'passes through when the map is an empty object' {
        Resolve-DFThemeName -Name 'catppuccin-mocha' -ThemeMap ([pscustomobject]@{}) |
            Should -Be 'catppuccin-mocha'
    }
}
