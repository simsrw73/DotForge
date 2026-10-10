BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Db = Import-DFToolDb -ToolsPath "$PSScriptRoot/../Tools" -Force
}
Describe 'Format-DFInstallCommand' {
    It 'formats a manager''s command for an id, and as a {0} template' {
        Format-DFInstallCommand -Manager $script:Db.scoop -Id glow | Should -Be 'scoop install glow'
        Format-DFInstallCommand -Manager $script:Db.scoop | Should -Be 'scoop install {0}'
    }
    It 'forms a feed-qualified id' {
        Format-DFInstallCommand -Manager $script:Db.scoop -Id ps-dotenv -Feed insomnia | Should -Be 'scoop install insomnia/ps-dotenv'
    }
    It 'formats the block for a given source' {
        Format-DFInstallCommand -Manager $script:Db.uv -Source uv -Id 3 | Should -Be 'uv python install --default 3'
        Format-DFInstallCommand -Manager $script:Db.uv -Source pypi -Id ruff | Should -Be 'uv tool install ruff'
    }
    It 'formats a function manager' {
        Format-DFInstallCommand -Manager $script:Db.psresource -Id PSFzf | Should -Match '^Install-PSResource -Name PSFzf'
    }
}
Describe 'Get-DFInstallHint' {
    It 'uses the best manager for the source, and returns nothing for a source no manager installs' {
        Get-DFInstallHint -Source choco -Id glow | Should -Be 'choco install glow -y'
        Get-DFInstallHint -Source nowhere -Id x | Should -BeNullOrEmpty
    }
}
Describe 'pickers and catalog hints read installs' {
    It 'has no hard-coded install command left in the picker sidecars or catalog providers' {
        $hits = git -C "$PSScriptRoot/.." grep -n -E "InstallCommand\s*=\s*'|InstallHint\s+""(scoop|winget|choco|cargo|npm) install|InstallHint\s+""Install-PSResource" -- Tools Private
        $hits | Should -BeNullOrEmpty
    }
}
