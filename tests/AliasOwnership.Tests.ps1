BeforeAll {
    $script:ManifestPath = "$PSScriptRoot/../DotForge.psd1"
    $script:GeneralHelperAliases = (Import-PowerShellDataFile -Path $script:ManifestPath).AliasesToExport
}

Describe 'DotForge module owns its general-helper aliases' {
    AfterEach {
        Remove-Module DotForge -ErrorAction Ignore
    }

    It 'exports every general-helper alias from the manifest' {
        Import-Module $script:ManifestPath -Force
        $exported = (Get-Module DotForge).ExportedAliases.Keys
        foreach ($name in $script:GeneralHelperAliases) {
            $exported | Should -Contain $name -Because "AliasesToExport declares '$name'"
        }
    }

    It 'resolves each alias to a command owned by the DotForge module' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in $script:GeneralHelperAliases) {
            $alias = Get-Alias -Name $name -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty -Because "'$name' should resolve after import"
            $alias.ModuleName | Should -Be 'DotForge' -Because "'$name' should be owned by DotForge, not created ad hoc"
        }
    }

    It 'removes every general-helper alias when the module is removed' {
        Import-Module $script:ManifestPath -Force
        Remove-Module DotForge
        foreach ($name in $script:GeneralHelperAliases) {
            Get-Alias -Name $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "'$name' should not survive Remove-Module"
        }
    }
}
