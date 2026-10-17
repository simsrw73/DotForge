BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # The shipped tool DB, keyed by name.
    $script:Db = @{}
    Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json' | ForEach-Object {
        $t = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $script:Db[$t.name] = $t
    }
}

Describe 'prompt engine ordering against zoxide' {
    BeforeEach { Reset-DFTestSession }
    # zoxide --hook pwd wraps function:prompt; a prompt engine initialized after
    # it replaces that wrapper and silently stops directory tracking.
    It '<Engine> registers before zoxide in the shipped tool set' -ForEach @(
        @{ Engine = 'starship' }
        @{ Engine = 'oh-my-posh' }
    ) {
        # .NET randomizes string hashes per process, so hash order can't be
        # relied on to expose a missing after — put zoxide first on purpose.
        $tools = @($script:Db['zoxide']) + @($script:Db.Values | Where-Object name -ne 'zoxide')
        $order = @(Invoke-DFTopoSort -Tools $tools).name
        $order.IndexOf($Engine) | Should -BeGreaterOrEqual 0
        $order.IndexOf($Engine) | Should -BeLessThan $order.IndexOf('zoxide')
    }
}

Describe 'starship companion' {
    BeforeEach { Reset-DFTestSession }
    It 'initializes starship from cached full-init output' {
        $src = Get-Content "$PSScriptRoot/../Tools/starship.ps1" -Raw
        $src | Should -Match "Get-DFCachedCommandOutput -Name 'starship-init' -Executable 'starship'"
        $src | Should -Match 'starship init powershell --print-full-init'
    }

    Context 'transient prompt helpers' {
        BeforeAll {
            # Stand-in for starship's init: like the real script, it defines its
            # helpers inside a dynamic module created with New-Module. Global so the
            # companion can see it from inside the module scope below.
            function global:Get-DFCachedCommandOutput {
                param($Name, $Executable, $Generate)
                '$null = New-Module starship { function Enable-TransientPrompt { ''enabled'' }; ' +
                'function Disable-TransientPrompt { }; ' +
                'Export-ModuleMember -Function Enable-TransientPrompt, Disable-TransientPrompt }'
            }
        }
        AfterAll {
            Remove-DFTestGlobal -Function 'Get-DFCachedCommandOutput'
            Remove-Module starship, DFCompanionHost -Force -ErrorAction Ignore
        }

        It 'exposes Enable-TransientPrompt globally when run from a module scope' {
            # Register-DFTool dot-sources companions inside DotForge's module session
            # state; without the global re-import the helpers stay stranded there.
            $companion = (Resolve-Path "$PSScriptRoot/../Tools/starship.ps1").Path
            $null = New-Module DFCompanionHost -ArgumentList $companion {
                param($Path)
                . $Path; . Initialize-DFRolePrompt -Role prompt
                # Like DotForge's manifest, export only the host's own functions
                # (none) — so nothing leaks out except what the companion re-imports.
                Export-ModuleMember -Function @()
            }
            (Get-Command Enable-TransientPrompt -ErrorAction Ignore)?.ModuleName | Should -Be 'starship'
            Enable-TransientPrompt | Should -Be 'enabled'
        }
    }
}

Describe 'starship XDG defaults' {
    BeforeEach { Reset-DFTestSession }
    It 'keeps its config in its own folder under XDG_CONFIG_HOME' {
        $script:Db['starship'].xdg.vars.STARSHIP_CONFIG | Should -Be '${XDG_CONFIG_HOME}/starship/starship.toml'
    }
}

Describe 'starship companion contract' {
    BeforeEach { Reset-DFTestSession }
    AfterEach { Remove-DFTestGlobal -Function 'Get-DFCachedCommandOutput' }

    It 'only defines its hook when dot-sourced; the prompt init runs only through the hook' {
        function global:Get-DFCachedCommandOutput { throw 'init ran outside the hook' }
        $definedHook = & { . "$PSScriptRoot/../Tools/starship.ps1"; Test-Path function:Initialize-DFRolePrompt }
        $definedHook | Should -BeTrue
    }
}

Describe 'starship follows Theme through a palette-swapped copy' {
    BeforeAll {
        $script:Palettes = Join-Path $PSScriptRoot '..' 'Tools' 'starship' 'catppuccin-palettes.toml'
        . (Join-Path $PSScriptRoot '..' 'Tools' 'starship.ps1')
        function script:New-StarshipFixture([string]$Text) {
            $file = Join-Path $TestDrive "src-$([guid]::NewGuid().ToString('N').Substring(0, 6)).toml"
            Set-Content -LiteralPath $file -Value $Text -NoNewline
            $file
        }
        $script:Full = @'
# my layout
"$schema" = 'x'
palette = "catppuccin_mocha"
format = "$all"

[palettes.catppuccin_mocha]
base = "#1e1e2e"

[palettes.catppuccin_latte]
base = "#eff1f5"

[palettes.catppuccin_frappe]
base = "#303446"
'@
    }
    BeforeEach { $script:Copy = Join-Path $TestDrive "copy-$([guid]::NewGuid().ToString('N').Substring(0, 6))" 'starship.toml' }
    AfterAll { Remove-DFTestGlobal -Function Invoke-DFApplyStarshipTheme }

    It 'copies the config with only the palette line changed' {
        $src = New-StarshipFixture $script:Full
        $path = Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes
        $path | Should -Be $script:Copy
        $before = @(Get-Content -LiteralPath $src); $after = @(Get-Content -LiteralPath $path)
        $after.Count | Should -Be $before.Count
        @(for ($i = 0; $i -lt $before.Count; $i++) { if ($before[$i] -cne $after[$i]) { $after[$i] } }) | Should -Be @('palette = "catppuccin_latte"')
    }
    It 'uses the source itself when its palette already matches, or it has no palette line' {
        $src = New-StarshipFixture $script:Full
        Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_mocha' -Copy $script:Copy -PalettesFile $script:Palettes | Should -Be $src
        $plain = New-StarshipFixture 'format = "$all"'
        Get-DFStarshipConfigPath -Source $plain -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes | Should -Be $plain
        Test-Path -LiteralPath $script:Copy | Should -BeFalse
    }
    It 'appends a palette table the source lacks' {
        $src = New-StarshipFixture $script:Full
        $path = Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_macchiato' -Copy $script:Copy -PalettesFile $script:Palettes
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^\[palettes\.catppuccin_macchiato\]'
        $text | Should -Match 'base = "#24273a"'
    }
    It 'changes only the top-level palette line, keeping a trailing comment' {
        $src = New-StarshipFixture @'
palette = 'catppuccin_mocha'  # flavor
[palettes.foo]
palette = "keep"
[palettes.catppuccin_latte]
base = "#eff1f5"
'@
        $text = Get-Content -LiteralPath (Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes) -Raw
        $text | Should -Match "(?m)^palette = 'catppuccin_latte'  # flavor"
        $text | Should -Match '(?m)^palette = "keep"'
    }
    It 'finds a palette line that comes after a multi-line format string (starship''s own preset layout)' {
        $src = New-StarshipFixture (@(
                '"$schema" = ''https://starship.rs/config-schema.json'''
                ''
                'format = """'
                '[](red)\'
                '$os\'
                '[](bg:peach fg:red)\'
                '"""'
                ''
                'palette = ''catppuccin_mocha'''
                ''
                '[palettes.catppuccin_latte]'
                'base = "#eff1f5"'
            ) -join "`n")
        $path = Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes
        $path | Should -Be $script:Copy
        Get-Content -LiteralPath $path -Raw | Should -Match "(?m)^palette = 'catppuccin_latte'"
        Get-Content -LiteralPath $path -Raw | Should -Match '(?m)^\[\]\(red\)\\'
    }
    It 'gives nothing for a missing source, without an error' {
        Get-DFStarshipConfigPath -Source (Join-Path $TestDrive 'nope.toml') -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes -ErrorAction Stop | Should -BeNullOrEmpty
    }
    It 'refreshes the copy when the source changes' {
        $src = New-StarshipFixture $script:Full
        $null = Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes
        Set-Content -LiteralPath $src -Value ($script:Full.Replace('format = "$all"', 'format = "changed"')) -NoNewline
        $null = Get-DFStarshipConfigPath -Source $src -Palette 'catppuccin_latte' -Copy $script:Copy -PalettesFile $script:Palettes
        Get-Content -LiteralPath $script:Copy -Raw | Should -Match 'format = "changed"'
    }
}

Describe 'starship theme in a session' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'starship'), (Join-Path $Env:XDG_CACHE_HOME 'dotforge') -Recurse -Force -ErrorAction Ignore
        $script:SavedConfig = $Env:STARSHIP_CONFIG
        Remove-Item Env:STARSHIP_CONFIG -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
        Mock Get-DFCachedCommandOutput { '' }
        $script:Source = Join-Path $Env:XDG_CONFIG_HOME 'starship' 'starship.toml'
        New-Item -ItemType Directory (Split-Path $script:Source) -Force | Out-Null
        Set-Content -LiteralPath $script:Source -Value "palette = `"catppuccin_mocha`"`n[palettes.catppuccin_mocha]`nbase = `"#1e1e2e`"`n" -NoNewline
        $script:CopyDir = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'starship'
        $script:CopyPath = Join-Path $script:CopyDir 'starship-catppuccin_latte.toml'
        $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
    }
    AfterEach {
        if ($null -ne $script:SavedConfig) { $Env:STARSHIP_CONFIG = $script:SavedConfig } else { Remove-Item Env:STARSHIP_CONFIG -ErrorAction Ignore }
        Remove-DFTestGlobal -Function Invoke-DFApplyStarshipTheme
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'points STARSHIP_CONFIG at a latte copy when Theme is catppuccin-latte' {
        Start-DFSession -Config @{ Tools = @('starship'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null
        $Env:STARSHIP_CONFIG | Should -Be $script:CopyPath
        Get-Content -LiteralPath $script:CopyPath -Raw | Should -Match 'palette = "catppuccin_latte"'
        Get-Content -LiteralPath $script:Source -Raw | Should -Match 'palette = "catppuccin_mocha"' -Because 'your file is never written'
    }
    It 'keeps your own file when the palette matches' {
        Start-DFSession -Config @{ Tools = @('starship') } -ToolsPath $script:Tools 3>$null
        $Env:STARSHIP_CONFIG | Should -Be $script:Source
    }
    It 'switches live with Set-DFToolTheme' {
        Start-DFSession -Config @{ Tools = @('starship') } -ToolsPath $script:Tools 3>$null
        $null = Set-DFToolTheme -Name starship -Theme catppuccin-frappe 3>$null
        $Env:STARSHIP_CONFIG | Should -Be (Join-Path $script:CopyDir 'starship-catppuccin_frappe.toml')
        Get-Content -LiteralPath $Env:STARSHIP_CONFIG -Raw | Should -Match 'palette = "catppuccin_frappe"'
    }
    It 'gives each palette its own copy, so a switch in one shell doesn''t change another' {
        Start-DFSession -Config @{ Tools = @('starship') } -ToolsPath $script:Tools 3>$null
        $null = Set-DFToolTheme -Name starship -Theme catppuccin-latte 3>$null
        $latte = $Env:STARSHIP_CONFIG
        $null = Set-DFToolTheme -Name starship -Theme catppuccin-frappe 3>$null
        $Env:STARSHIP_CONFIG | Should -Not -Be $latte
        Get-Content -LiteralPath $latte -Raw | Should -Match 'palette = "catppuccin_latte"' -Because 'another shell may still be using it'
    }
    It 'themes a STARSHIP_CONFIG you set yourself, without a warning, and never writes it' {
        $mine = Join-Path $TestDrive 'mine-starship.toml'
        Set-Content -LiteralPath $mine -Value "palette = `"catppuccin_mocha`"`n[palettes.catppuccin_latte]`nbase = `"#eff1f5`"`n" -NoNewline
        $Env:STARSHIP_CONFIG = $mine
        foreach ($config in @{ Tools = @('starship'); Theme = 'catppuccin-latte' }, @{ Tools = @('starship'); StarshipTheme = 'catppuccin-latte' }) {
            Reset-DFTestSession
            $Env:STARSHIP_CONFIG = $mine
            $warnings = @(Start-DFSession -Config $config -ToolsPath $script:Tools 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and "$_" -match 'STARSHIP_CONFIG' })
            $warnings | Should -BeNullOrEmpty
            $Env:STARSHIP_CONFIG | Should -Be $script:CopyPath
            Get-Content -LiteralPath $script:CopyPath -Raw | Should -Match 'palette = "catppuccin_latte"'
        }
        Get-Content -LiteralPath $mine -Raw | Should -Match 'palette = "catppuccin_mocha"'
    }
    It 'follows Theme in a nested shell that inherited DotForge''s copy' {
        New-Item -ItemType Directory (Split-Path $script:CopyPath) -Force | Out-Null
        Set-Content -LiteralPath $script:CopyPath -Value 'palette = "catppuccin_latte"'
        $Env:STARSHIP_CONFIG = $script:CopyPath
        Start-DFSession -Config @{ Tools = @('starship') } -ToolsPath $script:Tools 3>$null
        $Env:STARSHIP_CONFIG | Should -Be $script:Source
    }
    It 'notes once when your config sets no palette' {
        Set-Content -LiteralPath $script:Source -Value 'format = "$all"' -NoNewline
        Start-DFSession -Config @{ Tools = @('starship') } -ToolsPath $script:Tools 3>$null
        "$((Get-DFToolSetupState).starship.notes)" | Should -Match 'sets no palette'
    }
    It 'knows the StarshipTheme setting' {
        $script:DFConfigKeys.Keys | Should -Contain 'StarshipTheme'
    }
}
