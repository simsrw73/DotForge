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

Describe 'General-helper and tool/picker alias names never collide' {
    It 'no name in AliasesToExport is also declared by a Tools/*.json alias or picker' {
        $toolAliasNames = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
            $tool = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $aliases = $tool.PSObject.Properties['aliases']?.Value
            if ($aliases) {
                foreach ($n in $aliases.PSObject.Properties.Name) { [void]$toolAliasNames.Add($n) }
            }
            $picker = $tool.PSObject.Properties['picker']?.Value
            if ($picker -is [PSCustomObject]) {
                $pAlias = $picker.PSObject.Properties['alias']?.Value
                if ($pAlias) { [void]$toolAliasNames.Add($pAlias) }
            }
        }

        $collisions = $script:GeneralHelperAliases | Where-Object { $toolAliasNames.Contains($_) }
        $collisions | Should -BeNullOrEmpty -Because 'a general-helper alias and a tool/picker alias must never share a name'
    }
}
