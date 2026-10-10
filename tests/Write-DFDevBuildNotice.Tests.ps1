#Requires -Version 7.2
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Write-DFDevBuildNotice' {
    It 'names a dev build, its version and where it is installed' {
        $out = Write-DFDevBuildNotice -Version '0.7.1' -Prerelease 'dev20261010150113' -Location 'C:\Modules\DotForge\0.7.1' 6>&1
        "$out" | Should -BeLike '*DotForge 0.7.1-dev20261010150113*developer build*C:\Modules\DotForge\0.7.1*'
    }

    It 'says nothing for a Gallery release, preview or stable' {
        Write-DFDevBuildNotice -Version '0.7.0' -Prerelease 'preview' -Location 'C:\x' 6>&1 | Should -BeNullOrEmpty
        Write-DFDevBuildNotice -Version '1.0.0' -Prerelease '' -Location 'C:\x' 6>&1 | Should -BeNullOrEmpty
    }

    It 'says nothing when DotForge runs from source files, not an installed module' {
        Write-DFDevBuildNotice 6>&1 | Should -BeNullOrEmpty
    }
}

Describe 'Start-DFSession shows the dev-build notice' {
    BeforeEach { Set-DFTestXdg; Reset-DFTestSession }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'asks for the notice before loading tools' {
        Mock Write-DFDevBuildNotice { }
        Start-DFSession -Config @{ Tools = @() } 3>$null
        Should -Invoke Write-DFDevBuildNotice -Times 1 -Exactly
    }
}
