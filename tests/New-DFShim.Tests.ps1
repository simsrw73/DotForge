BeforeAll {
    . "$PSScriptRoot/../Public/New-DFDirectory.ps1"
    . "$PSScriptRoot/../Private/Expand-DFXdgPath.ps1"
    . "$PSScriptRoot/../Private/Import-DFToolDb.ps1"
    . "$PSScriptRoot/../Public/New-DFShim.ps1"
}

Describe 'New-DFShim' {
    BeforeEach {
        $script:DFToolDb = $null
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore

        # Set up a fake app directory and executable
        $script:AppDir  = Join-Path $TestDrive 'myapp'
        $script:FakeExe = Join-Path $script:AppDir 'myapp.exe'
        New-Item -ItemType Directory -Force -Path $script:AppDir  | Out-Null
        New-Item -ItemType File      -Force -Path $script:FakeExe | Out-Null

        # Dedicated shims dir for most tests
        $script:ShimsDir = Join-Path $TestDrive 'shims'

        # Save PATH so we can restore it
        $script:SavedPath = $Env:PATH
    }

    AfterEach {
        $Env:PATH = $script:SavedPath
        Remove-Variable DFConfig -Scope Global -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'creates a .cmd file in the specified shims dir' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        Test-Path (Join-Path $script:ShimsDir 'myapp.cmd') | Should -BeTrue
    }

    It 'generated .cmd contains the correct target path' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape("`"$($script:FakeExe)`" %*"))
    }

    It 'generated .cmd contains cd /d to the app directory' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape("cd /d `"$($script:AppDir)`""))
    }

    It 'uses ShimsPath from $DFConfig when -ShimsPath is not specified' {
        $configDir = Join-Path $TestDrive 'config-shims'
        $Global:DFConfig = @{ ShimsPath = $configDir }
        New-DFShim -Name 'myapp' -Target $script:FakeExe
        Test-Path (Join-Path $configDir 'myapp.cmd') | Should -BeTrue
    }

    It 'falls back to $HOME\.local\bin when no $DFConfig ShimsPath is set' {
        $defaultDir = Join-Path $HOME '.local' 'bin'
        $shimPath   = Join-Path $defaultDir 'dfshimtest.cmd'
        try {
            New-DFShim -Name 'dfshimtest' -Target $script:FakeExe 3>$null
            Test-Path $shimPath | Should -BeTrue
        } finally {
            Remove-Item $shimPath -ErrorAction Ignore
        }
    }

    It 'warns when shims dir is not on $PATH' {
        # $script:ShimsDir is a fresh TestDrive path — not on PATH
        $warns = New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warns | Should -Not -BeNullOrEmpty
    }

    It 'does not warn when shims dir is already on $PATH' {
        $Env:PATH = $script:ShimsDir + [IO.Path]::PathSeparator + $Env:PATH
        $warns = New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warns | Should -BeNullOrEmpty
    }

    It 'resolves target from tool DB when -Target is omitted' {
        $toolsDir = Join-Path $TestDrive 'tools'
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
        @'
{ "name": "myapp", "executable": "myapp.exe" }
'@ | Set-Content (Join-Path $toolsDir 'myapp.json')

        Mock Get-Command {
            [PSCustomObject]@{ Source = $script:FakeExe }
        } -ParameterFilter { $Name -eq 'myapp.exe' }

        New-DFShim -Name 'myapp' -ShimsPath $script:ShimsDir -ToolsPath $toolsDir
        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape($script:FakeExe))

        Remove-Item $toolsDir -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It '-Target bypasses the tool DB entirely' {
        $toolsDir = Join-Path $TestDrive 'emptytools'
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

        New-DFShim -Name 'directapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir `
            -ToolsPath $toolsDir
        Test-Path (Join-Path $script:ShimsDir 'directapp.cmd') | Should -BeTrue

        Remove-Item $toolsDir -Recurse -Force -ErrorAction Ignore
        $script:DFToolDb = $null
    }

    It 'errors when -Target file does not exist' {
        { New-DFShim -Name 'ghost' -Target 'C:\nonexistent\ghost.exe' `
            -ShimsPath $script:ShimsDir -ErrorAction Stop } |
            Should -Throw
    }

    It 'errors when tool name is not in DB and -Target is omitted' {
        $emptyDir = Join-Path $TestDrive 'emptytools2'
        New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
        { New-DFShim -Name 'notregistered' -ShimsPath $script:ShimsDir `
            -ToolsPath $emptyDir -ErrorAction Stop } |
            Should -Throw
        $script:DFToolDb = $null
    }

    It '-Force overwrites an existing shim' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir

        $newExe = Join-Path $script:AppDir 'myapp2.exe'
        New-Item -ItemType File -Force -Path $newExe | Out-Null
        New-DFShim -Name 'myapp' -Target $newExe -ShimsPath $script:ShimsDir -Force

        $content = Get-Content (Join-Path $script:ShimsDir 'myapp.cmd') -Raw
        $content | Should -Match ([regex]::Escape($newExe))
    }

    It 'errors without -Force when shim already exists' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe -ShimsPath $script:ShimsDir
        { New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir -ErrorAction Stop } |
            Should -Throw
    }

    It '-WhatIf does not create the shim file' {
        New-DFShim -Name 'myapp' -Target $script:FakeExe `
            -ShimsPath $script:ShimsDir -WhatIf
        Test-Path (Join-Path $script:ShimsDir 'myapp.cmd') | Should -BeFalse
    }
}
