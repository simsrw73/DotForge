BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    Reset-DFTestSession
    $script:Listing = (Get-DFRoleDb -Path "$PSScriptRoot/../data/roles.json")['listing']
    function script:Get-ListingAliases([string]$Name) {
        $tool = Get-DFTestToolRecord $Name
        Get-DFRoleBehaviorAlias -RoleDefinition $script:Listing -Block $tool.roles.listing -Tool $tool
    }
}

# The exact arguments each listing alias runs, so a mapping change is a deliberate edit.
Describe 'listing behaviors' {
    It 'eza: <Alias>' -ForEach @(
        @{ Alias = 'ls'; Expected = @('--color=auto', '--icons=auto', '--group-directories-first', '--no-quotes') }
        @{ Alias = 'll'; Expected = @('--long', '--color=auto', '--icons=auto', '--group-directories-first', '--git', '--no-quotes') }
        @{ Alias = 'la'; Expected = @('--long', '--all', '--color=auto', '--icons=auto', '--group-directories-first', '--git', '--no-quotes') }
        @{ Alias = 'tree'; Expected = @('--tree', '--no-quotes') }
    ) {
        (Get-ListingAliases 'eza').$Alias.args | Should -Be $Expected
    }

    It 'lsd: <Alias>' -ForEach @(
        @{ Alias = 'ls'; Expected = @('--color=auto', '--icon=auto', '--group-directories-first', '--literal') }
        @{ Alias = 'll'; Expected = @('--long', '--color=auto', '--icon=auto', '--group-directories-first', '--git', '--literal') }
        @{ Alias = 'la'; Expected = @('--long', '--all', '--color=auto', '--icon=auto', '--group-directories-first', '--git', '--literal') }
        @{ Alias = 'tree'; Expected = @('--tree', '--literal') }
    ) {
        (Get-ListingAliases 'lsd').$Alias.args | Should -Be $Expected
    }

    It 'ff lists through the winner: <Name>' -ForEach @(
        @{ Name = 'eza'; List = 'eza -1 --icons=always --color=always --no-quotes' }
        @{ Name = 'lsd'; List = 'lsd -1 --icon=always --color=always --literal' }
    ) {
        $tool = Get-DFTestToolRecord $Name
        (Get-DFRolePicker -RoleDefinition $script:Listing -Block $tool.roles.listing -Tool $tool)[0].list | Should -Be $List
    }

    It 'eza no longer declares its own ff picker' {
        (Get-DFTestToolRecord 'eza').picker | Should -BeNullOrEmpty
    }
}

Describe 'listing behaviors without a Nerd Font' {
    BeforeEach { Mock Test-DFIconsOn { $false } }

    It 'eza: <Alias> has no icons' -ForEach @(
        @{ Alias = 'ls'; Expected = @('--color=auto', '--group-directories-first', '--no-quotes') }
        @{ Alias = 'll'; Expected = @('--long', '--color=auto', '--group-directories-first', '--git', '--no-quotes') }
    ) {
        (Get-ListingAliases 'eza').$Alias.args | Should -Be $Expected
    }

    It 'ff lists without icons: <Name>' -ForEach @(
        @{ Name = 'eza'; List = 'eza -1 --color=always --no-quotes' }
        @{ Name = 'lsd'; List = 'lsd -1 --color=always --literal' }
    ) {
        $tool = Get-DFTestToolRecord $Name
        (Get-DFRolePicker -RoleDefinition $script:Listing -Block $tool.roles.listing -Tool $tool)[0].list | Should -Be $List
    }
}
