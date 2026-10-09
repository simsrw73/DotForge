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
}
