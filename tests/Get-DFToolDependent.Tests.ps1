BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Get-DFToolDependent' {
    BeforeAll {
        $script:Db = @{
            fzf           = Rec '{ "name": "fzf", "executable": "fzf" }'
            PSFzf         = Rec '{ "name": "PSFzf", "executable": "PSFzf", "type": "module", "requires": ["fzf"] }'
            fzfplus       = Rec '{ "name": "fzfplus", "executable": "fzfplus", "requires": ["PSFzf"] }'
            node          = Rec '{ "name": "node", "executable": "node", "roles": { "js-runtime": {} } }'
            bun           = Rec '{ "name": "bun", "executable": "bun", "roles": { "js-runtime": {} } }'
            inshellisense = Rec '{ "name": "inshellisense", "executable": "is", "requires": ["role:js-runtime"] }'
        }
    }
    It 'lists active tools that require it' {
        Get-DFToolDependent -Name fzf -ToolDb $script:Db -Active fzf, PSFzf | Should -Be @('PSFzf')
    }
    It 'ignores tools that are not active' {
        Get-DFToolDependent -Name fzf -ToolDb $script:Db -Active fzf | Should -BeNullOrEmpty
    }
    It 'follows requires chains with -Transitive, deepest dependent first' {
        Get-DFToolDependent -Name fzf -ToolDb $script:Db -Active fzf, PSFzf, fzfplus -Transitive | Should -Be @('fzfplus', 'PSFzf')
    }
    It 'counts the only active member of a required role' {
        Get-DFToolDependent -Name node -ToolDb $script:Db -Active node, inshellisense | Should -Be @('inshellisense')
    }
    It 'does not blame a tool that is not the role''s active member' {
        Get-DFToolDependent -Name bun -ToolDb $script:Db -Active node, inshellisense | Should -BeNullOrEmpty
    }
    It 'does not count a role member when another member is active' {
        Get-DFToolDependent -Name node -ToolDb $script:Db -Active node, bun, inshellisense | Should -BeNullOrEmpty
    }
}
