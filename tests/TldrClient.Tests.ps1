BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Tools = Join-Path $PSScriptRoot '..' 'Tools'

    # The picker's list command, as Set-DFPickerFunction receives it.
    function script:Get-TldrPickerList([string]$Winner) {
        $role = (Get-DFRoleDb)['tldr-client']
        $tool = ConvertTo-DFToolRecord (Get-Content (Join-Path $script:Tools "$Winner.json") -Raw | ConvertFrom-Json)
        (Get-DFRolePicker -RoleDefinition $role -Block $tool.roles.'tldr-client' -Tool $tool)[0].list
    }
}

Describe 'tldr-client role' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'tealdeer'), (Join-Path $Env:XDG_CONFIG_HOME 'tlrc') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'Select-TldrPage'
        Remove-Alias ftldr -Scope Global -Force -ErrorAction Ignore
        Remove-Item Env:TEALDEER_CONFIG_DIR, Env:TLRC_CONFIG -ErrorAction Ignore
        Restore-DFTestXdg; Set-DFTestConfig $null
    }

    It 'lists every page through the winner''s own flag' {
        Get-TldrPickerList 'tealdeer' | Should -Be 'tldr --list'
        Get-TldrPickerList 'tlrc' | Should -Be 'tldr --list-all'
    }
    It 'picks tealdeer by default, and Defaults can pick tlrc' {
        Start-DFSession -Config @{ Tools = @('tealdeer', 'tlrc') } -ToolsPath $script:Tools 3>$null 6>$null
        (Get-DFRole -Name 'tldr-client').Winner | Should -Be 'tealdeer'
        Reset-DFTestSession
        Start-DFSession -Config @{ Tools = @('tealdeer', 'tlrc'); Defaults = @{ 'tldr-client' = 'tlrc' } } -ToolsPath $script:Tools 3>$null 6>$null
        (Get-DFRole -Name 'tldr-client').Winner | Should -Be 'tlrc'
    }
    It 'defines the ftldr picker' {
        Start-DFSession -Config @{ Tools = @('tealdeer') } -ToolsPath $script:Tools 3>$null 6>$null
        Get-Command Select-TldrPage -CommandType Function | Should -Not -BeNullOrEmpty
        (Get-Alias -Name ftldr -Scope Global).Definition | Should -Be 'Select-TldrPage'
    }
    It 'points tealdeer at its XDG config folder and tlrc at its XDG config file' {
        Start-DFSession -Config @{ Tools = @('tealdeer', 'tlrc') } -ToolsPath $script:Tools 3>$null 6>$null
        $Env:TEALDEER_CONFIG_DIR | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'tealdeer')
        $Env:TLRC_CONFIG | Should -Be (Join-Path $Env:XDG_CONFIG_HOME 'tlrc' 'config.toml')
    }
    It 'seeds <tool>''s config with the catppuccin-mocha colors' -ForEach @(@{ tool = 'tealdeer' }, @{ tool = 'tlrc' }) {
        Start-DFSession -Config @{ Tools = @($tool) } -ToolsPath $script:Tools 3>$null 6>$null
        $config = Join-Path $Env:XDG_CONFIG_HOME $tool 'config.toml'
        Get-Content $config -Raw | Should -Be (Get-Content (Join-Path $script:Tools $tool 'catppuccin-mocha' 'config.toml') -Raw)
    }
    It 'follows Theme' {
        Start-DFSession -Config @{ Tools = @('tlrc'); Theme = 'catppuccin-latte' } -ToolsPath $script:Tools 3>$null 6>$null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'tlrc' 'config.toml') -Raw | Should -Match '#8839ef'
    }
    It 'keeps an existing config' {
        $config = Join-Path $Env:XDG_CONFIG_HOME 'tealdeer' 'config.toml'
        New-Item -ItemType Directory (Split-Path $config) -Force | Out-Null
        Set-Content $config '# mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('tealdeer') } -ToolsPath $script:Tools 3>$null 6>$null
        Get-Content $config -Raw | Should -Be '# mine'
    }
    It 'prefers winget and avoids scoop' -ForEach @(@{ tool = 'tealdeer' }, @{ tool = 'tlrc' }) {
        $record = Get-Content (Join-Path $script:Tools "$tool.json") -Raw | ConvertFrom-Json
        $record.install.prefer | Should -Be @('winget')
        $record.install.avoid.scoop | Should -Not -BeNullOrEmpty
    }
}
