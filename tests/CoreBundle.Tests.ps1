#Requires -Version 7.0
# Bundle/DotForge.Core.ps1 is the startup core (Shared/, Private/, Public/) as one
# file: dot-sourcing one file is ~0.3 s faster than 58. If this fails, a core
# source changed without regenerating it: run
#   ./build/Build-DFCoreBundle.ps1
# and commit the result. (An edited source never loads stale code: the module
# falls back to the files whenever the bundle's hash doesn't match.)

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    function script:Invoke-DFChild([string]$Root, [string]$Script, [hashtable]$Vars = @{}) {
        $set = ($Vars.GetEnumerator() | ForEach-Object { "`$Env:$($_.Key) = '$($_.Value)'; " }) -join ''
        @(pwsh -NoProfile -NonInteractive -Command "$set Import-Module '$Root/DotForge.psd1'; $Script" 2>&1 | ForEach-Object { "$_" })
    }
}

Describe 'Bundle/DotForge.Core.ps1' {
    It 'matches what build/Build-DFCoreBundle.ps1 generates' {
        $fresh = Join-Path $TestDrive 'DotForge.Core.ps1'
        pwsh -NoProfile -NonInteractive -File (Join-Path $script:Repo 'build' 'Build-DFCoreBundle.ps1') -OutputPath $fresh | Out-Null
        Test-Path $fresh | Should -BeTrue
        (Get-Content $fresh -Raw) -replace '\r', '' | Should -Be ((Get-Content (Join-Path $script:Repo 'Bundle' 'DotForge.Core.ps1') -Raw) -replace '\r', '')
    }
    It 'is what Import-Module loads when it is current' {
        $r = @(Invoke-DFChild $script:Repo "(Get-Command Start-DFSession).ScriptBlock.File")
        $r[-1] | Should -BeLike '*Bundle*DotForge.Core.ps1'
    }
    It 'is skipped when DF_NO_BUNDLE is set' {
        $r = @(Invoke-DFChild $script:Repo "(Get-Command Start-DFSession).ScriptBlock.File" @{ DF_NO_BUNDLE = '1' })
        $r[-1] | Should -BeLike '*Public*Start-DFSession.ps1'
    }
    It 'is skipped when a core source changed since it was built' {
        $copy = Join-Path $TestDrive 'edited'
        New-Item -ItemType Directory $copy | Out-Null
        foreach ($i in 'DotForge.psd1', 'DotForge.psm1', 'Shared', 'Private', 'Public', 'Bundle', 'Modules') { Copy-Item (Join-Path $script:Repo $i) $copy -Recurse }
        Add-Content (Join-Path $copy 'Private' 'Invoke-DFTopoSort.ps1') "`n# an edit not yet bundled"
        $r = @(Invoke-DFChild $copy "(Get-Command Start-DFSession).ScriptBlock.File")
        $r[-1] | Should -BeLike '*edited*Public*Start-DFSession.ps1'
    }
    It 'defines exactly the functions the separate files define' {
        $files = foreach ($d in 'Shared', 'Private', 'Public') { Get-ChildItem (Join-Path $script:Repo $d) -Filter '*.ps1' }
        $fromFiles = foreach ($f in $files) {
            [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text }
        }
        $fromBundle = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'Bundle' 'DotForge.Core.ps1'), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text }
        @($fromBundle | ForEach-Object { $_ -replace '\r', '' }) | Should -Be @($fromFiles | ForEach-Object { $_ -replace '\r', '' })
    }
}
