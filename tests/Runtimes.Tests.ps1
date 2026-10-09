BeforeAll {
    $script:J = @{}
    foreach ($n in 'node', 'bun', 'pnpm', 'npm', 'fnm', 'mise', 'inshellisense') {
        $p = "$PSScriptRoot/../Tools/$n.json"
        $script:J[$n] = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json }
    }
}
Describe 'runtimes and version managers (install spec, section 8)' {
    It 'makes node and bun the js-runtime members, and takes fnm and mise out' {
        $script:J.node.roles.PSObject.Properties.Name | Should -Contain 'js-runtime'
        $script:J.bun.roles.PSObject.Properties.Name | Should -Contain 'js-runtime'
        $script:J.fnm.roles.PSObject.Properties.Name | Should -Not -Contain 'js-runtime'
        $script:J.mise.roles.PSObject.Properties.Name | Should -Not -Contain 'js-runtime'
    }
    It 'installs node through a version manager first, and checks it after them' {
        $script:J.node.install.prefer[0] | Should -Be 'fnm'
        $script:J.node.after | Should -Contain 'role:version-manager'
    }
    It 'makes npm come with node, and bun a js-package-manager too' {
        $script:J.npm.requires | Should -Contain 'node'
        $script:J.bun.roles.PSObject.Properties.Name | Should -Contain 'js-package-manager'
        $script:J.pnpm.installs.from | Should -Be 'npm'
    }
}
