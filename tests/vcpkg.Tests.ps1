BeforeAll {
    $script:RealTools    = Join-Path $PSScriptRoot '../Tools'
    $script:CompanionPath = Join-Path $script:RealTools 'vcpkg.ps1'
    . "$PSScriptRoot/../Private/ConvertTo-DFPath.ps1"
    . "$PSScriptRoot/../Public/Add-DFToPath.ps1"
}

Describe 'vcpkg tool JSON' {
    It 'relocates VCPKG_ROOT under XDG_DATA_HOME and VCPKG_DOWNLOADS under XDG_CACHE_HOME' {
        $j = Get-Content (Join-Path $script:RealTools 'vcpkg.json') -Raw | ConvertFrom-Json
        $j.xdg.vars.VCPKG_ROOT      | Should -Be '${XDG_DATA_HOME}/vcpkg'
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
}
