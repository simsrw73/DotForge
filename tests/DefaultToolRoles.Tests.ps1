BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    . "$PSScriptRoot/../Private/Test-DFOutputPiped.ps1"
    . "$PSScriptRoot/../Private/Write-DFFileAtomic.ps1"
    . "$PSScriptRoot/../Private/DFCatalog.Base.ps1"
    . "$PSScriptRoot/../Private/DFReleaseData.ps1"
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
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
    . "$PSScriptRoot/../Private/Get-DFCoreutilsShadowSet.ps1"
    . "$PSScriptRoot/../Public/Get-DFCommandConflict.ps1"
    . "$PSScriptRoot/../Private/Initialize-DFCompletionStack.ps1"
    . "$PSScriptRoot/../Private/Get-DFConfiguredTheme.ps1"
    . "$PSScriptRoot/../Private/Resolve-DFThemeName.ps1"
    . "$PSScriptRoot/../Private/Set-DFToolXdgConfig.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolAliases.ps1"
    . "$PSScriptRoot/../Private/New-DFToolPickerFunction.ps1"
    . "$PSScriptRoot/../Private/Invoke-DFToolCompanion.ps1"
    . "$PSScriptRoot/../Private/Start-DFModulePrewarm.ps1"
    . "$PSScriptRoot/../Private/Get-DFRoleDb.ps1"
    . "$PSScriptRoot/../Private/Write-DFRoleNotice.ps1"
    . "$PSScriptRoot/../Private/Set-DFRoleEnv.ps1"
    . "$PSScriptRoot/../Private/Register-DFToolSteps.ps1"
    . "$PSScriptRoot/../Public/Register-DFTool.ps1"
    $script:RealTools = Join-Path $PSScriptRoot '../Tools'
}

Describe 'eza/lsd share role: listing (real tool records)' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        Mock Get-Command {
            param($Name)
            if ($Name -in 'eza.exe', 'lsd.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        Mock Write-DFConflictNotice { }
        # Stand-ins so a wrapper's `& eza ...` / `& lsd ...` resolves to a capturable
        # function (Function resolves before Application), whether or not the real
        # binaries are installed. A .GetNewClosure() wrapper's ScriptBlock.ToString()
        # shows only the unbound template, so calling it is the only reliable probe.
        function global:eza { $global:LastCommandCalled = 'eza' }
        function global:lsd { $global:LastCommandCalled = 'lsd' }
    }
    AfterEach {
        Remove-Variable DFConfig, LastCommandCalled -Scope Global -ErrorAction Ignore
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        # eza's real picker block also defines Select-File and its ff alias.
        Remove-DFTestGlobal -Function ls, ll, la, tree, Select-File, eza, lsd -Alias ff
    }

    It 'declares listing on both tools, with the listing aliases inside the role block' {
        foreach ($name in 'eza', 'lsd') {
            $j = Get-Content (Join-Path $script:RealTools "$name.json") -Raw | ConvertFrom-Json
            $j.roles.listing.aliases.PSObject.Properties.Name | Should -Be @('ls', 'll', 'la', 'tree')
            @($j.aliases.PSObject.Properties).Count | Should -Be 0
            $j.PSObject.Properties['role'] | Should -BeNullOrEmpty
        }
    }

    It 'gives the listing aliases to <Winner> when Defaults.listing = <Winner>' -ForEach @(@{ Winner = 'eza' }, @{ Winner = 'lsd' }) {
        $Global:DFConfig = @{ Defaults = @{ listing = $Winner } }
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        foreach ($a in 'ls', 'll', 'la', 'tree') { & $a; $global:LastCommandCalled | Should -Be $Winner -Because $a }
    }

    It 'gives the listing aliases to eza by priority when Defaults is absent' {
        Register-DFTool -Name 'eza', 'lsd' -ToolsPath $script:RealTools -WarningAction SilentlyContinue
        & 'ls'; $global:LastCommandCalled | Should -Be 'eza'
    }
}

Describe 'oh-my-posh/starship share role: prompt (real tool records and sidecars)' {
    BeforeAll { . "$PSScriptRoot/../Private/Get-DFCachedCommandOutput.ps1" }
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:DFRoleDb = $null
        $script:DFRoleEnvSet = @{}
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:SavedXdg = @{}
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            $script:SavedXdg[$v] = [Environment]::GetEnvironmentVariable("XDG_$($v)_HOME")
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", (Join-Path $TestDrive "$($v.ToLower())-$([guid]::NewGuid())"))
        }
        $script:SavedPoshTheme = $Env:POSH_THEME
        Remove-Item Env:POSH_THEME -ErrorAction Ignore
        # One oh-my-posh config for the sidecar to discover.
        $ompDir = Join-Path $Env:XDG_CONFIG_HOME 'oh-my-posh'
        New-Item -ItemType Directory -Force $ompDir | Out-Null
        '{}' | Set-Content (Join-Path $ompDir 'test.omp.json')

        $global:PromptInits = @()
        Mock Get-Command {
            param($Name)
            if ($Name -in 'oh-my-posh.exe', 'starship.exe') { [PSCustomObject]@{ Path = "C:\fake\$Name" } }
        }
        Mock Get-Module { }   # no posh-git, so the oh-my-posh hook skips its import
        Mock Write-DFConflictNotice { }
        Mock Initialize-DFCompletionStack { }
        Mock Get-DFCachedCommandOutput { '$global:PromptInits += "starship"' } -ParameterFilter { $Name -eq 'starship-init' }
        # oh-my-posh's init output is piped to Invoke-Expression; emit a line that records the call.
        function global:oh-my-posh { '$global:PromptInits += "oh-my-posh"' }
    }
    AfterEach {
        Remove-Variable DFConfig, PromptInits -Scope Global -ErrorAction Ignore
        foreach ($v in 'CONFIG', 'CACHE', 'STATE', 'DATA') {
            [Environment]::SetEnvironmentVariable("XDG_$($v)_HOME", $script:SavedXdg[$v])
        }
        if ($null -eq $script:SavedPoshTheme) { Remove-Item Env:POSH_THEME -ErrorAction Ignore } else { $Env:POSH_THEME = $script:SavedPoshTheme }
        Remove-Item Env:POSH_THEMES_PATH, Env:STARSHIP_CONFIG, Env:STARSHIP_CACHE -ErrorAction Ignore
        Remove-DFTestGlobal -Function oh-my-posh, Select-PoshTheme
        # Remove-DFTestGlobal's alias guard (Test-Path alias:global:...) misses this one; remove it directly.
        Remove-Alias -Name fpot -Scope Global -Force -ErrorAction Ignore
    }

    It 'initializes only oh-my-posh by priority, defines fpot, and warns once' {
        Register-DFTool -Name 'oh-my-posh', 'starship' -ToolsPath $script:RealTools -WarningVariable w -WarningAction SilentlyContinue
        $global:PromptInits | Should -Be @('oh-my-posh')
        (Get-Alias fpot -ErrorAction Ignore).Definition | Should -Be 'Select-PoshTheme'
        "$w" | Should -Match 'prompt role; using oh-my-posh'
    }

    It 'initializes only starship when Defaults.prompt = starship, and leaves fpot undefined' {
        $Global:DFConfig = @{ Defaults = @{ prompt = 'starship' } }
        Register-DFTool -Name 'oh-my-posh', 'starship' -ToolsPath $script:RealTools -WarningVariable w -WarningAction SilentlyContinue
        $global:PromptInits | Should -Be @('starship')
        Get-Alias fpot -ErrorAction Ignore | Should -BeNullOrEmpty
        "$w" | Should -Not -Match 'prompt role'
    }
}
