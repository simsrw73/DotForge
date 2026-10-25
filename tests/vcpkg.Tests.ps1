BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:RealTools    = Join-Path $PSScriptRoot '../Tools'
    $script:CompanionPath = Join-Path $script:RealTools 'vcpkg.ps1'


}

Describe 'vcpkg tool JSON' {
    It 'relocates VCPKG_DOWNLOADS under XDG_CACHE_HOME and leaves VCPKG_ROOT to the installer' {
        $j = Get-Content (Join-Path $script:RealTools 'vcpkg.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.PSObject.Properties['VCPKG_ROOT'] | Should -BeNullOrEmpty
        $j.xdg.vars.VCPKG_DOWNLOADS | Should -Be '${XDG_CACHE_HOME}/vcpkg/downloads'
    }
}

Describe 'vcpkg companion' {
    BeforeEach {
        $script:SavedPath = $Env:Path
        $script:SavedVcpkgRoot = $Env:VCPKG_ROOT
        $Env:Path        = 'C:\Windows\System32'
        $Env:VCPKG_ROOT  = 'C:\fake\xdg-data\vcpkg'
    }

    AfterEach {
        $Env:Path       = $script:SavedPath
        $Env:VCPKG_ROOT = $script:SavedVcpkgRoot
    }

    It 'adds $VCPKG_ROOT itself to PATH (vcpkg.exe has no bin/ subfolder)' {
        . $script:CompanionPath
        ($Env:Path -split [IO.Path]::PathSeparator) | Should -Contain 'C:\fake\xdg-data\vcpkg'
    }
    It 'adds nothing to PATH when VCPKG_ROOT is unset' {
        Remove-Item Env:\VCPKG_ROOT -ErrorAction Ignore
        { . $script:CompanionPath } | Should -Not -Throw
        $Env:Path | Should -Be 'C:\Windows\System32'
    }
}
