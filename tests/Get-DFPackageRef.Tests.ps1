BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Get-DFPackageRef' {
    It 'reads a plain id' {
        $r = Get-DFPackageRef 'glow'
        $r.Id | Should -Be 'glow'
        $r.Feed | Should -BeNullOrEmpty
    }
    It 'reads an id with a feed' {
        $r = Get-DFPackageRef ('{ "id": "ps-dotenv", "feed": { "name": "insomnia", "url": "https://x" } }' | ConvertFrom-Json)
        $r.Id | Should -Be 'ps-dotenv'
        $r.Feed.name | Should -Be 'insomnia'
    }
    It 'returns nothing for an empty value' {
        Get-DFPackageRef '' | Should -BeNullOrEmpty
    }
}

Describe 'shipped packages use source keys' {
    It 'never uses the old manager keys cargo, psresource or scoopBucket' {
        foreach ($f in Get-ChildItem "$PSScriptRoot/../Tools" -Filter '*.json') {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $j.PSObject.Properties['scoopBucket'] | Should -BeNullOrEmpty -Because $f.Name
            if ($j.PSObject.Properties['packages'] -and $j.packages) {
                $j.packages.PSObject.Properties.Name | Should -Not -Contain 'cargo' -Because $f.Name
                $j.packages.PSObject.Properties.Name | Should -Not -Contain 'psresource' -Because $f.Name
            }
        }
    }
    It 'puts ps-dotenv''s third-party bucket in a feed' {
        $j = Get-Content "$PSScriptRoot/../Tools/ps-dotenv.json" -Raw | ConvertFrom-Json
        $j.packages.scoop.feed.name | Should -Be 'insomnia'
    }
}

Describe 'package readers accept a feed object' {
    BeforeEach { Set-DFTestXdg; Reset-DFTestSession }
    AfterEach { Restore-DFTestXdg }
    It 'Get-DFCatalogInstalled keys a feed package by its id' {
        $dir = Join-Path $TestDrive "pr-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "fd2", "executable": "fd2.exe", "packages": { "scoop": { "id": "fd2", "feed": { "name": "b", "url": "https://x" } } } }' |
            Set-Content (Join-Path $dir 'fd2.json')
        $r = Get-DFCatalogInstalled -ToolsPath $dir -FetchItems { @() }
        $r.IdentityMap['scoop:fd2'] | Should -Be 'fd2'
    }
}
