BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'admin categories' {
    It 'defines process-viewer and disk-usage as categories, with no hook or aliases' {
        $db = Get-DFRoleDb
        foreach ($name in 'process-viewer', 'disk-usage') {
            $db[$name].kind | Should -Be 'category'
            $db[$name].hook | Should -BeNullOrEmpty
            $db[$name].description | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'process viewers follow the tool contract' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'procs'), (Join-Path $Env:XDG_CONFIG_HOME 'bottom'), (Join-Path $Env:XDG_CONFIG_HOME 'glances') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        # Stand-in executables: the wrappers call them by name and these record the arguments.
        foreach ($exe in 'procs.exe', 'btm.exe', 'glances.exe') { Set-Item "function:global:$exe" -Value { "args=$($args -join '|')" } }
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'procs.exe', 'btm.exe', 'glances.exe', 'procs', 'btm', 'glances', 'Select-Process'
        Remove-Alias fkill -Scope Global -Force -ErrorAction Ignore
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'joins process-viewer: <Name>' -ForEach @(@{ Name = 'procs' }, @{ Name = 'bottom' }, @{ Name = 'glances' }, @{ Name = 'ntop' }, @{ Name = 'pstop' }) {
        $record = (Import-DFToolDb -ToolsPath $script:Tools -Name $Name)[$Name]
        $record.roles.PSObject.Properties.Name | Should -Contain 'process-viewer'
    }
    It 'gives procs your theme and passes your arguments through unchanged' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name procs -ToolsPath $script:Tools 3>$null 6>$null
        procs -d -p x | Should -Be 'args=--theme|light|-d|-p|x'
    }
    It 'loads procs'' config from its XDG folder once it exists' {
        $config = Join-Path $Env:XDG_CONFIG_HOME 'procs' 'config.toml'
        New-Item -ItemType File -Force $config | Out-Null
        Register-DFTool -Name procs -ToolsPath $script:Tools 3>$null 6>$null
        procs | Should -Be "args=--theme|dark|--load-config|$config"
    }
    It 'gives bottom a light or dark built-in theme and its XDG config' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name bottom -ToolsPath $script:Tools 3>$null 6>$null
        btm -d | Should -Be 'args=--theme|default-light|-d'
        $config = Join-Path $Env:XDG_CONFIG_HOME 'bottom' 'bottom.toml'
        New-Item -ItemType File -Force $config | Out-Null
        btm | Should -Be "args=--theme|default-light|-C|$config"
    }
    It 'passes glances its XDG config only once it exists' {
        Register-DFTool -Name glances -ToolsPath $script:Tools 3>$null 6>$null
        glances -1 | Should -Be 'args=-1'
        $config = Join-Path $Env:XDG_CONFIG_HOME 'glances' 'glances.conf'
        New-Item -ItemType File -Force $config | Out-Null
        glances | Should -Be "args=-C|$config"
    }
    It 'notes that htop is pstop on Windows' {
        (Import-DFToolDb -ToolsPath $script:Tools -Name pstop).pstop.description | Should -Match 'htop'
    }
    It 'knows ProcsTheme and BottomTheme' {
        $script:DFConfigKeys.Keys | Should -Contain 'ProcsTheme'
        $script:DFConfigKeys.Keys | Should -Contain 'BottomTheme'
    }
}

Describe 'disk-usage tools follow the tool contract' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Join-Path $Env:XDG_CONFIG_HOME 'gdu') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        foreach ($exe in 'gdu.exe', 'duf.exe') { Set-Item "function:global:$exe" -Value { "args=$($args -join '|')" } }
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'gdu.exe', 'duf.exe', 'gdu', 'duf'
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'joins disk-usage: <Name>' -ForEach @(@{ Name = 'dust' }, @{ Name = 'dua' }, @{ Name = 'gdu' }, @{ Name = 'duf' }) {
        $record = (Import-DFToolDb -ToolsPath $script:Tools -Name $Name)[$Name]
        $record.roles.PSObject.Properties.Name | Should -Contain 'disk-usage'
    }
    It 'passes gdu its XDG config only once it exists, and your arguments unchanged' {
        Register-DFTool -Name gdu -ToolsPath $script:Tools 3>$null 6>$null
        gdu -d -p x | Should -Be 'args=-d|-p|x'
        $config = Join-Path $Env:XDG_CONFIG_HOME 'gdu' 'gdu.yaml'
        New-Item -ItemType File -Force $config | Out-Null
        gdu | Should -Be "args=--config-file|$config"
    }
    It 'gives duf a light or dark theme from Theme' {
        Set-DFTestConfig @{ Theme = 'catppuccin-latte' }
        Register-DFTool -Name duf -ToolsPath $script:Tools 3>$null 6>$null
        duf | Should -Be 'args=-theme|light'
        Reset-DFTestSession; Remove-DFTestGlobal -Function duf
        Set-DFTestConfig @{ Theme = 'catppuccin-mocha' }
        Register-DFTool -Name duf -ToolsPath $script:Tools 3>$null 6>$null
        duf | Should -Be 'args=-theme|dark'
    }
    It 'registers dua''s own completions, cached' {
        Mock Get-DFCachedCommandOutput { '$global:DuaCompleterLoaded = $true' } -ParameterFilter { $Name -eq 'dua-completions' }
        Register-DFTool -Name dua -ToolsPath $script:Tools 3>$null 6>$null
        $global:DuaCompleterLoaded | Should -BeTrue
        Remove-Variable DuaCompleterLoaded -Scope Global -ErrorAction Ignore
    }
    It 'puts dust in +admin-tools' {
        $groups = Get-Content (Join-Path $PSScriptRoot '..' 'data' 'groups.json') -Raw | ConvertFrom-Json
        $groups.'admin-tools'.tools | Should -Contain 'dust'
    }
    It 'knows DufTheme' {
        $script:DFConfigKeys.Keys | Should -Contain 'DufTheme'
    }
}
