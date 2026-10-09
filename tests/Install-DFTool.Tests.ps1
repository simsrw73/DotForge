BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Install-DFTool' {
    BeforeEach {
        $script:DFToolDb          = $null
        $script:DFPackageManagers = $null
        $script:DFToolAvailability = @{}
        $script:TmpTools = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null

        @'
{
  "name": "pkgtool",
  "executable": "pkgtool.exe",
  "packages": { "scoop": "pkgtool-scoop", "winget": "Vendor.pkgtool" }
}
'@ | Set-Content (Join-Path $script:TmpTools 'pkgtool.json')

        @'
{ "name": "nopkg", "executable": "nopkg.exe", "packages": {} }
'@ | Set-Content (Join-Path $script:TmpTools 'nopkg.json')

        Set-DFTestConfig $null
    }

    It 'warns for an unknown tool name' {
        Install-DFTool -Name 'nosuch' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'nosuch' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when no package manager is available for the tool' {
        Mock Get-Command { $null }
        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'warns when the available PM has no package for the tool' {
        Mock Get-Command { if ($Name -eq 'choco') { [PSCustomObject]@{ Name = 'choco' } } else { $null } }
        Install-DFTool -Name 'pkgtool' -PackageManager 'choco' -ToolsPath $script:TmpTools -WarningVariable warns 3>$null
        $warns | Where-Object { $_ -match 'pkgtool' } | Should -Not -BeNullOrEmpty
    }

    It 'uses -PackageManager override when specified' {
        $script:ScoopCalled = $false
        function script:scoop { $script:ScoopCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools
        $script:ScoopCalled | Should -BeTrue
    }

    It 'uses the InstallOrder setting when set' {
        Set-DFTestConfig @{ InstallOrder = @('winget') }
        $script:WingetCalled = $false
        function script:winget { $script:WingetCalled = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Install-DFTool -Name 'pkgtool' -ToolsPath $script:TmpTools
        $script:WingetCalled | Should -BeTrue
        Set-DFTestConfig $null
    }

    It 'tolerates $DFConfig being set to $null' {
        # Regression: guarding on the variable's existence rather than its value
        # threw "Cannot index into a null array" for a profile with $DFConfig = $null.
        Set-DFTestConfig $null
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        function script:scoop { $global:LASTEXITCODE = 0 }
        { Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools } |
            Should -Not -Throw
        Set-DFTestConfig $null
    }

    It 'installs a cargo-only tool via cargo when scoop/winget/choco lack it' {
        @'
{ "name": "cargotool", "executable": "cargotool.exe", "packages": { "crates": "cargotool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'cargotool.json')
        $script:DFToolDb = $null

        $script:CargoArgs = $null
        function script:cargo { $script:CargoArgs = $args; $global:LASTEXITCODE = 0 }
        # cargo present; the default managers are not
        Mock Get-Command { if ($Name -eq 'cargo') { [PSCustomObject]@{ Name = 'cargo' } } else { $null } }

        Install-DFTool -Name 'cargotool' -ToolsPath $script:TmpTools
        ($script:CargoArgs -join ' ') | Should -Match 'install\s+cargotool'
    }

    It 'prefers scoop over cargo when both are declared and available' {
        @'
{ "name": "dualtool", "executable": "dualtool.exe", "packages": { "scoop": "dualtool", "crates": "dualtool" } }
'@ | Set-Content (Join-Path $script:TmpTools 'dualtool.json')
        $script:DFToolDb = $null

        $script:ScoopHit = $false; $script:CargoHit = $false
        function script:scoop { $script:ScoopHit = $true; $global:LASTEXITCODE = 0 }
        function script:cargo { $script:CargoHit = $true; $global:LASTEXITCODE = 0 }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }   # everything available

        Install-DFTool -Name 'dualtool' -ToolsPath $script:TmpTools
        $script:ScoopHit | Should -BeTrue
        $script:CargoHit | Should -BeFalse
    }

    It 'does not throw when -WhatIf is specified' {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        { Install-DFTool -Name 'pkgtool' -PackageManager 'scoop' -ToolsPath $script:TmpTools -WhatIf } |
            Should -Not -Throw
    }

    It 'processes multiple tool names in a single call' {
        Mock Get-Command { $null }
        Install-DFTool -Name @('pkgtool', 'nopkg', 'nosuch') -ToolsPath $script:TmpTools `
            -WarningVariable warns 3>$null
        @($warns).Count | Should -Be 3
    }

    It 'installs via Install-PSResource when psresource package is specified' {
        @'
{ "name": "psmod", "type": "module", "executable": "PsMod",
  "packages": { "psgallery": "PsMod" } }
'@ | Set-Content (Join-Path $script:TmpTools 'psmod.json')
        $script:DFToolDb = $null

        $script:PSResourceCalled = $false
        function script:Install-PSResource {
            param($Name, $Scope, $ErrorAction)
            $script:PSResourceCalled = $true
        }
        Mock Get-Command { [PSCustomObject]@{ Name = 'Install-PSResource' } } `
            -ParameterFilter { $Name -eq 'Install-PSResource' }

        Install-DFTool -Name 'psmod' -PackageManager 'psresource' -ToolsPath $script:TmpTools
        $script:PSResourceCalled | Should -BeTrue

        Remove-Item (Join-Path $script:TmpTools 'psmod.json') -ErrorAction Ignore
        $script:DFToolDb = $null
    }
}

Describe 'Install-DFTool with a scoop bucket' {
    BeforeEach {
        $script:DFToolDb = $null
        $script:DFToolAvailability = @{}
        $script:TmpTools = Join-Path $TestDrive "tools-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force -Path $script:TmpTools | Out-Null
        @'
{ "name": "bucktool", "executable": "bucktool.exe",
  "packages": { "scoop": { "id": "bucktool", "feed": { "name": "testbucket", "url": "https://example.invalid/bucket" } } } }
'@ | Set-Content (Join-Path $script:TmpTools 'bucktool.json')
        $script:ScoopCalls = [System.Collections.Generic.List[string]]::new()
        $script:Buckets = @('main')
        $script:BucketAddExit = 0
        $script:ListCalls = 0
        $script:ListFailures = 0
        function script:scoop {
            $script:ScoopCalls.Add(($args -join ' '))
            if ($args[0] -eq 'bucket' -and $args[1] -eq 'list') {
                $script:ListCalls++
                if ($script:ListCalls -le $script:ListFailures) { $global:LASTEXITCODE = 1; return }
                $script:Buckets | ForEach-Object { [pscustomobject]@{ Name = $_ } }; $global:LASTEXITCODE = 0; return
            }
            if ($args[0] -eq 'bucket' -and $args[1] -eq 'add') { $global:LASTEXITCODE = $script:BucketAddExit; return }
            $global:LASTEXITCODE = 0
        }
        Mock Get-Command { [PSCustomObject]@{ Name = $Name } }
        Set-DFTestConfig $null
    }
    AfterEach { Remove-Item function:scoop -ErrorAction Ignore }

    It 'adds a missing bucket, then installs the bucket-qualified package' {
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        $script:ScoopCalls | Should -Contain 'bucket add testbucket https://example.invalid/bucket'
        $script:ScoopCalls | Should -Contain 'install testbucket/bucktool'
    }

    It 'skips the add when the bucket is already there' {
        $script:Buckets = @('main', 'testbucket')
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        @($script:ScoopCalls | Where-Object { $_ -like 'bucket add*' }).Count | Should -Be 0
        $script:ScoopCalls | Should -Contain 'install testbucket/bucktool'
    }

    It 'warns and does not install when the bucket cannot be added' {
        $script:BucketAddExit = 1
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools -WarningVariable w -WarningAction SilentlyContinue 6>$null
        "$w" | Should -Match "testbucket"
        @($script:ScoopCalls | Where-Object { $_ -like 'install*' }).Count | Should -Be 0
    }

    It 'prints the bucket message on its own line, before the install progress line' {
        $info = @(Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools 6>&1 | ForEach-Object { "$_" })
        $added = [array]::FindIndex([string[]]$info, [Predicate[string]] { param($l) $l -match 'added scoop bucket' })
        $installing = [array]::FindIndex([string[]]$info, [Predicate[string]] { param($l) $l -match 'Installing bucktool' })
        $added | Should -BeGreaterOrEqual 0
        $added | Should -BeLessThan $installing
    }

    It 'installs when a failed add turns out to be a bucket that was already there' {
        $script:ListFailures = 1          # the first list errors, so the bucket looks missing
        $script:Buckets = @('main', 'testbucket')
        $script:BucketAddExit = 1         # scoop refuses: it already exists
        Install-DFTool -Name bucktool -PackageManager scoop -ToolsPath $script:TmpTools -WarningVariable w -WarningAction SilentlyContinue 6>$null
        $w | Should -BeNullOrEmpty
        $script:ScoopCalls | Should -Contain 'install testbucket/bucktool'
    }

    It 'installs an unqualified id when the tool declares no bucket' {
        '{ "name": "plain", "executable": "plain.exe", "packages": { "scoop": "plain" } }' | Set-Content (Join-Path $script:TmpTools 'plain.json')
        Install-DFTool -Name plain -PackageManager scoop -ToolsPath $script:TmpTools 6>$null
        $script:ScoopCalls | Should -Contain 'install plain'
        @($script:ScoopCalls | Where-Object { $_ -like 'bucket*' }).Count | Should -Be 0
    }
}
