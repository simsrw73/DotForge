BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    function script:New-RoleRecord([string]$Name, [string[]]$Roles) {
        $roleSet = [pscustomobject]@{}
        foreach ($role in @($Roles | Where-Object { $_ })) { $roleSet | Add-Member -NotePropertyName $role -NotePropertyValue ([pscustomobject]@{}) }
        [pscustomobject]@{ name = $Name; roles = $roleSet }
    }
}

Describe 'ConvertFrom-DFToolReference' {
    It 'reads a tool name' {
        $ref = ConvertFrom-DFToolReference -Reference 'fzf'
        $ref.Kind | Should -Be 'Tool'
        $ref.Name | Should -Be 'fzf'
    }

    It 'reads a role reference' {
        $ref = ConvertFrom-DFToolReference -Reference 'role:js-runtime'
        $ref.Kind | Should -Be 'Role'
        $ref.Name | Should -Be 'js-runtime'
    }

    It 'accepts the characters tool names use' {
        (ConvertFrom-DFToolReference -Reference 'oh-my-posh').Name | Should -Be 'oh-my-posh'
        (ConvertFrom-DFToolReference -Reference 'Terminal-Icons').Name | Should -Be 'Terminal-Icons'
        (ConvertFrom-DFToolReference -Reference 'role:tab.completion_2').Name | Should -Be 'tab.completion_2'
    }

    It 'returns nothing for a malformed reference: <Reference>' -ForEach @(
        @{ Reference = '' }, @{ Reference = 'role:' }, @{ Reference = 'bad name' },
        @{ Reference = '-leading-dash' }, @{ Reference = 'role:role:x' }, @{ Reference = 'Role:x y' }
    ) {
        ConvertFrom-DFToolReference -Reference $Reference | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFRoleMember' {
    BeforeAll {
        $script:Tools = @(
            New-RoleRecord 'nvm'  @('js-runtime')
            New-RoleRecord 'fnm'  @('js-runtime', 'version-manager')
            New-RoleRecord 'bat'  @('pager')
            New-RoleRecord 'plain' @()
        )
    }

    It 'returns the records that join the role, sorted by name' {
        (Get-DFRoleMember -Role 'js-runtime' -Tools $script:Tools).name | Should -Be @('fnm', 'nvm')
    }

    It 'returns nothing when no record joins the role' {
        Get-DFRoleMember -Role 'editor' -Tools $script:Tools | Should -BeNullOrEmpty
    }

    It 'accepts an empty set of records' {
        Get-DFRoleMember -Role 'pager' -Tools @() | Should -BeNullOrEmpty
    }

    It 'skips null entries' {
        (Get-DFRoleMember -Role 'pager' -Tools @($null, $script:Tools[2])).name | Should -Be 'bat'
    }
}
