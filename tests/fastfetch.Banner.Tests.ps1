BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Part = . "$PSScriptRoot/../Tools/fastfetch.banner.ps1"
    $script:Fixture = Get-Content "$PSScriptRoot/fixtures/banner/fastfetch.txt"
    function New-Tool([string]$ConfigPath) {
        [pscustomobject]@{ name = 'fastfetch'; settings = [pscustomobject]@{ configPath = $ConfigPath } }
    }
}

# fastfetch's banner part: the body, its colors and the public IP
# (docs/superpowers/specs/2026-10-11-startup-banner-design.md).
Describe 'fastfetch banner part' {
    BeforeEach { Set-DFTestXdg }
    AfterEach { Restore-DFTestXdg }

    It 'takes its colors and separator from the fastfetch config in use' {
        $config = Join-Path $TestDrive 'ff.jsonc'
        Set-Content $config '{ "display": { "separator": " : ", "color": { "keys": "#010203", "output": "35" } } }'
        $style = & $script:Part.Style ([pscustomobject]@{ Tool = New-Tool $config })
        $style.KeyColor | Should -Be '#010203'
        $style.OutputColor | Should -Be '35'
        $style.Separator | Should -Be ' : '
    }
    It 'reads a config with comments' {
        $config = Join-Path $TestDrive 'ffc.jsonc'
        Set-Content $config "{`n  // mine`n  `"display`": { `"color`": { `"keys`": `"#010203`" } }`n}"
        (& $script:Part.Style ([pscustomobject]@{ Tool = New-Tool $config })).KeyColor | Should -Be '#010203'
    }
    It 'falls back to the seeded config''s colors when there is no config' {
        $style = & $script:Part.Style ([pscustomobject]@{ Tool = New-Tool (Join-Path $TestDrive 'none.jsonc') })
        $style.KeyColor | Should -Be '#cba6f7'
    }
    It 'asks for fastfetch and the public IP in the background' {
        $work = & $script:Part.Work ([pscustomobject]@{ Tool = New-Tool (Join-Path $TestDrive 'none.jsonc') })
        @($work.Name) | Should -Be @('fastfetch', 'publicip')
    }
    It 'returns fastfetch''s lines as the body and the IP as a fill' {
        $done = & $script:Part.Complete @{ fastfetch = $script:Fixture; publicip = @('203.0.113.4') } ([pscustomobject]@{})
        @($done.Body).Count | Should -Be @($script:Fixture).Count
        $done.Fills.publicip[0].Value | Should -Be '203.0.113.4'
        $done.Fills.publicip[0].Key | Should -BeNullOrEmpty
    }
    It 'gives no IP fill for an answer that is not an address' {
        @((& $script:Part.Complete @{ publicip = @('<html>oops</html>') } ([pscustomobject]@{})).Fills.publicip).Count | Should -Be 0
    }
    It 'gives no body when fastfetch did not finish' {
        (& $script:Part.Complete @{} ([pscustomobject]@{})).Body | Should -BeNullOrEmpty
    }
}

Describe 'The fastfetch wrapper fills placeholders from the cache' {
    BeforeEach {
        Set-DFTestXdg
        $config = Join-Path $TestDrive 'wrap.jsonc'
        Copy-Item "$PSScriptRoot/../Tools/fastfetch/config.jsonc" $config
        $global:DFTestFastfetchLines = $script:Fixture
        function global:fastfetch.exe { $global:DFTestFastfetchLines }
        $DFCurrentTool = New-Tool $config
        . "$PSScriptRoot/../Tools/fastfetch.ps1"
    }
    AfterEach {
        Remove-DFTestGlobal -Function 'fastfetch', 'fastfetch.exe'
        Remove-Variable DFTestFastfetchLines -Scope Global -ErrorAction Ignore
        Restore-DFTestXdg
    }

    It 'never shows placeholder text' {
        $out = (fastfetch | Out-String) -replace "$([char]27)\[[0-9;]*m", ''
        $out | Should -Not -Match '@DF:'
        $out | Should -Match 'Local IP'
    }
    It 'shows a cached value, marked' {
        Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value '{ "publicip": { "at": "x", "items": [ { "Key": null, "Value": "203.0.113.4", "Alert": false } ] } }'
        $out = (fastfetch | Out-String) -replace "$([char]27)\[[0-9;]*m", ''
        $out | Should -Match 'Public IP  203\.0\.113\.4 \(cached\)'
    }
}
