BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/mise.ps1'
}

Describe 'mise companion' {
    BeforeEach {
        $script:SavedPath = $Env:Path
        Set-DFTestXdg

    }
    AfterEach {
        $Env:Path = $script:SavedPath
        Remove-DFTestGlobal -Function mise
        Remove-Variable MiseActivated -Scope Global -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'puts its shims on PATH from the body, without activating' {
        function global:mise { $global:MiseActivated = $true }
        . $script:CompanionPath
        ($Env:Path -split ';') | Should -Contain (Join-Path $Env:XDG_DATA_HOME 'mise\shims')
        $global:MiseActivated | Should -BeNullOrEmpty
    }

    It 'activates through its project-env hook' {
        function global:mise { '$global:MiseActivated = $true' }
        . $script:CompanionPath
        . Initialize-DFRoleProjectEnv -Role project-env
        $global:MiseActivated | Should -BeTrue
    }
}

Describe 'mise activation scope' {
    AfterEach { Remove-DFTestGlobal -Function mise, _dfprobe_wrapper }

    It 'keeps functions the activation defines (such as its mise wrapper) after the hook returns' {
        function global:mise { 'function _dfprobe_wrapper { ''wrapped'' }' }
        & { . "$PSScriptRoot/../Tools/mise.ps1"; . Initialize-DFRoleProjectEnv -Role project-env }
        _dfprobe_wrapper | Should -Be 'wrapped'
    }
}

Describe 'Tools/mise.json' {
    It 'registers after the prompt engines, because activation wraps the prompt' {
        $j = Get-Content (Join-Path $PSScriptRoot '../Tools/mise.json') -Raw | ConvertFrom-Json
        $j.after | Should -Contain 'oh-my-posh'
        $j.after | Should -Contain 'starship'
    }

    It 'is the default project-env tool, ahead of ps-dotenv and direnv' {
        $priority = foreach ($name in 'mise', 'ps-dotenv', 'direnv') {
            (Get-Content (Join-Path $PSScriptRoot "../Tools/$name.json") -Raw | ConvertFrom-Json).roles.'project-env'.priority
        }
        $priority[0] | Should -BeGreaterThan ([Math]::Max($priority[1], $priority[2]))
    }
}

Describe 'mise .env loader seed' {
    BeforeAll {
        $script:Record = ConvertTo-DFToolRecord (Get-Content (Join-Path $PSScriptRoot '../Tools/mise.json') -Raw | ConvertFrom-Json)
        $script:ToolsPath = Join-Path $PSScriptRoot '../Tools'
    }
    BeforeEach { Set-DFTestXdg }
    AfterEach { Restore-DFTestXdg }

    It 'seeds a conf.d fragment that loads .env files only after approval' {
        $action = @(Invoke-DFToolSeed -Tool $script:Record -ToolsPath $script:ToolsPath)
        $dest = Join-Path $Env:XDG_CONFIG_HOME 'mise\conf.d\dotenv.toml'
        $action.path | Should -Be $dest
        $action.created | Should -BeTrue
        $text = Get-Content $dest -Raw
        $text | Should -Match '(?m)^env_file = "\.env"'
        $text | Should -Match '(?m)^paranoid = \["env_files"\]'
        $text | Should -Match '(?m)^# trusted_config_paths' -Because 'no folder is approved for everyone'
    }

    It 'keeps an existing fragment' {
        $dest = Join-Path $Env:XDG_CONFIG_HOME 'mise\conf.d\dotenv.toml'
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        'mine' | Set-Content $dest
        @(Invoke-DFToolSeed -Tool $script:Record -ToolsPath $script:ToolsPath).created | Should -BeFalse
        Get-Content $dest | Should -Be 'mine'
    }

    It 'warns about a .env in the home folder, which every folder under it would load' {
        $note = @($script:Record.setup.notes) | Where-Object { $_.ifFile -eq '~/.env' }
        $note | Should -Not -BeNullOrEmpty
        $note.text | Should -Match 'mise trust'
    }
}
