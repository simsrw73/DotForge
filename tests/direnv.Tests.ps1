BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:CompanionPath = Join-Path $PSScriptRoot '../Tools/direnv.ps1'
    $script:OriginalLocationChangedAction = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
}

Describe 'direnv tool JSON' {
    It 'is natively XDG-compliant -- no xdg.vars needed' {
        $j = Get-Content (Join-Path $PSScriptRoot '../Tools/direnv.json') -Raw | ConvertFrom-Json
        $j.xdg.method | Should -Be 'default'
    }
}

# Scoped narrowly to the hook caching, mirroring zoxide.Tests.ps1/carapace.Tests.ps1.
Describe 'direnv tool sidecar caching' -Skip:(-not (Get-Command direnv.exe -ErrorAction Ignore)) {
    BeforeEach {
        $script:SavedCacheHome = $Env:XDG_CACHE_HOME
        $Env:XDG_CACHE_HOME    = Join-Path $TestDrive 'cache'
        Remove-Item $Env:XDG_CACHE_HOME -Recurse -Force -ErrorAction Ignore
    }
    AfterEach {
        $Env:XDG_CACHE_HOME = $script:SavedCacheHome
        # Uninstall the real hook the test installed; see the last Describe.
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:OriginalLocationChangedAction
    }

    It 'caches the real hook script, and does not regenerate it on a second load' {
        # Genuinely calls the real direnv binary -- see carapace.Tests.ps1 for why
        # a function stand-in would defeat this test (no fingerprintable .Source).
        . $script:CompanionPath; . Initialize-DFRoleProjectEnv -Role project-env
        $cacheFile = Join-Path $Env:XDG_CACHE_HOME 'dotforge' 'direnv-hook.txt'
        Test-Path $cacheFile | Should -BeTrue
        $writtenAfterFirst = (Get-Item $cacheFile).LastWriteTimeUtc

        Start-Sleep -Milliseconds 50
        . $script:CompanionPath; . Initialize-DFRoleProjectEnv -Role project-env

        (Get-Item $cacheFile).LastWriteTimeUtc | Should -Be $writtenAfterFirst
    }
}

Describe 'direnv companion helpers' {
    BeforeAll { . $script:CompanionPath }

    It 'finds Git bash from <Layout>' -ForEach @(
        @{ Layout = 'mingw64\bin\git.exe'; Git = 'Git\mingw64\bin\git.exe' }
        @{ Layout = 'cmd\git.exe';         Git = 'Git\cmd\git.exe' }
    ) {
        $root = Join-Path $TestDrive "g-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force (Join-Path $root 'Git\bin'), (Split-Path (Join-Path $root $Git)) | Out-Null
        New-Item -ItemType File (Join-Path $root 'Git\bin\bash.exe'), (Join-Path $root $Git) | Out-Null
        Find-DFGitBash -GitPath (Join-Path $root $Git) | Should -Be (Join-Path $root 'Git\bin\bash.exe')
    }

    It 'follows a scoop shim to the real git before walking up' {
        $root = Join-Path $TestDrive "s-$([guid]::NewGuid())"
        $real = Join-Path $root 'apps\git\current\cmd\git.exe'
        $bash = Join-Path $root 'apps\git\current\bin\bash.exe'
        $shim = Join-Path $root 'shims\git.exe'
        foreach ($f in $real, $bash, $shim) { New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; New-Item -ItemType File $f | Out-Null }
        "path = `"$real`"" | Set-Content (Join-Path $root 'shims\git.shim')
        Find-DFGitBash -GitPath $shim | Should -Be $bash
    }

    It 'never returns a bash under WINDIR' {
        $savedWindir = $Env:WINDIR
        try {
            $win = Join-Path $TestDrive "win-$([guid]::NewGuid())"
            $Env:WINDIR = $win
            $git = Join-Path $win 'tools\git.exe'
            foreach ($f in $git, (Join-Path $win 'bin\bash.exe')) { New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; New-Item -ItemType File $f | Out-Null }
            Find-DFGitBash -GitPath $git | Should -BeNullOrEmpty
        } finally { $Env:WINDIR = $savedWindir }
    }

    It 'returns nothing when no bin\bash.exe sits above git' {
        $git = Join-Path $TestDrive 'nobash\git.exe'
        New-Item -ItemType Directory -Force (Split-Path $git) | Out-Null
        New-Item -ItemType File $git | Out-Null
        Find-DFGitBash -GitPath $git | Should -BeNullOrEmpty
    }

    It 'flags <Text> as buggy: <Buggy>' -ForEach @(
        @{ Text = "2.37.1`n"; Buggy = $true }
        @{ Text = '2.36.0';   Buggy = $true }
        @{ Text = '2.38.0';   Buggy = $false }
        @{ Text = 'garbage';  Buggy = $false }
    ) {
        Test-DFDirenvBuggyVersion -VersionText $Text | Should -Be $Buggy
    }
}

Describe 'direnv project-env hook' {
    BeforeEach {
        $script:SavedBash = $Env:DIRENV_BASH
        $script:SavedLca = $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction
        . $script:CompanionPath
        Mock Get-DFCachedCommandOutput { '$null' } -ParameterFilter { $Name -eq 'direnv-hook' }
        Mock Get-DFCachedCommandOutput { $script:VersionText } -ParameterFilter { $Name -eq 'direnv-version' }
        $script:VersionText = '2.37.1'
    }
    AfterEach {
        if ($null -eq $script:SavedBash) { Remove-Item Env:DIRENV_BASH -ErrorAction Ignore } else { $Env:DIRENV_BASH = $script:SavedBash }
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction = $script:SavedLca
    }

    It 'leaves a DIRENV_BASH the user set alone' {
        $Env:DIRENV_BASH = 'C:\mine\bash.exe'
        . Initialize-DFRoleProjectEnv -Role project-env 3>$null
        $Env:DIRENV_BASH | Should -Be 'C:\mine\bash.exe'
    }

    It 'sets DIRENV_BASH from Git bash when unset' {
        Remove-Item Env:DIRENV_BASH -ErrorAction Ignore
        Mock Find-DFGitBash { 'C:\Git\bin\bash.exe' }
        . Initialize-DFRoleProjectEnv -Role project-env 3>$null
        $Env:DIRENV_BASH | Should -Be 'C:\Git\bin\bash.exe'
    }

    It 'warns when no Git bash is found' {
        Remove-Item Env:DIRENV_BASH -ErrorAction Ignore
        Mock Find-DFGitBash { }
        $w = . Initialize-DFRoleProjectEnv -Role project-env 3>&1
        "$w" | Should -Match "needs Git for Windows' bash"
    }

    It 'warns about the Windows bug for 2.37.1, and not for 2.38.0' {
        $Env:DIRENV_BASH = 'C:\x\bash.exe'
        $w1 = . Initialize-DFRoleProjectEnv -Role project-env 3>&1
        "$w1" | Should -Match 'direnv#1488'
        $script:VersionText = '2.38.0'
        $w2 = . Initialize-DFRoleProjectEnv -Role project-env 3>&1
        "$w2" | Should -Not -Match 'direnv#1488'
    }
}

# Runs after the caching test. direnv's real hook attaches to the process-wide
# LocationChangedAction; left installed, every later Set-Location in the run calls
# direnv, which on Windows can unload variables such as PATH.
Describe 'direnv tests clean up after themselves' {
    It 'leaves LocationChangedAction as it found it' {
        $ExecutionContext.SessionState.InvokeCommand.LocationChangedAction | Should -Be $script:OriginalLocationChangedAction
    }
}
