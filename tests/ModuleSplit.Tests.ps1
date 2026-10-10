#Requires -Version 7.2
# The startup core and the on-demand modules (docs/superpowers/specs/2026-10-10-module-split-design.md).
# These run a real Import-Module in a child pwsh: auto-loading only happens with real modules.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    function script:Invoke-DFChild([string]$Script) {
        $code = "`$ErrorActionPreference = 'Stop'; Import-Module '$script:Repo/DotForge.psd1'; $Script"
        $out = pwsh -NoProfile -NonInteractive -Command $code 2>&1
        @($out | ForEach-Object { "$_" })
    }
    function script:Get-Manifest([string]$Path) { Import-PowerShellDataFile (Join-Path $script:Repo $Path) }
    $script:Manifests = @{
        DotForge = 'DotForge.psd1'
        'DotForge.Catalog' = 'Modules/DotForge.Catalog/DotForge.Catalog.psd1'
        'DotForge.Helpers' = 'Modules/DotForge.Helpers/DotForge.Helpers.psd1'
    }
}

Describe 'the startup core and the on-demand modules' {
    It 'imports without loading the catalog or the helpers' {
        $r = @(Invoke-DFChild "(Get-Module).Name -join ','")
        $r[-1] | Should -Match 'DotForge'
        $r[-1] | Should -Not -Match 'DotForge\.(Catalog|Helpers)'
    }
    It 'auto-loads the catalog on first use of one of its commands' {
        $r = @(Invoke-DFChild "(Get-Command Find-DFPackage).Module.Name; (Get-Module).Name -join ','")
        $r[-2] | Should -Be 'DotForge.Catalog'
        $r[-1] | Should -Match 'DotForge\.Catalog'
    }
    It 'keeps every alias in the core, so it beats a program of the same name, and auto-loads its target' {
        $r = @(Invoke-DFChild "(Get-Command which).CommandType; (Get-Command which).Source; (Get-Command (Get-Command env).Definition).Module.Name; (Get-Command (Get-Command trifle).Definition).Module.Name")
        $r[0] | Should -Be 'Alias'
        $r[1] | Should -Be 'DotForge'
        $r[2] | Should -Be 'DotForge.Helpers'
        $r[3] | Should -Be 'DotForge.Catalog'
    }
    It 'exports Get-DFConfig, which returns the session''s value' {
        $r = @(Invoke-DFChild "Start-DFSession -Config @{ Tools = @(); Theme = 'nord' } 3>`$null 6>`$null | Out-Null; Get-DFConfig Theme")
        $r[-1] | Should -Be 'nord'
    }
}

Describe 'the three manifests' {
    It 'export exactly the functions in their Public folders' {
        foreach ($k in $script:Manifests.Keys) {
            $m = Get-Manifest $script:Manifests[$k]
            $dir = Join-Path (Split-Path (Join-Path $script:Repo $script:Manifests[$k])) 'Public'
            $defined = foreach ($f in Get-ChildItem $dir -Filter '*.ps1') {
                [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false).Name
            }
            @($m.FunctionsToExport | Sort-Object) | Should -Be @($defined | Where-Object { $_ -ne 'DFAliases' } | Sort-Object -Unique) -Because $k
        }
    }
    It 'export aliases only from the core, and every alias target is exported by one of them' {
        $all = foreach ($k in $script:Manifests.Keys) { (Get-Manifest $script:Manifests[$k]).FunctionsToExport }
        (Get-Manifest $script:Manifests['DotForge.Catalog']).AliasesToExport | Should -BeNullOrEmpty
        (Get-Manifest $script:Manifests['DotForge.Helpers']).AliasesToExport | Should -BeNullOrEmpty
        $r = @(Invoke-DFChild "foreach (`$a in (Get-Module DotForge).ExportedAliases.Values) { `$a.Definition }")
        foreach ($target in $r) { $all | Should -Contain $target }
    }
    It 'have the same version' {
        $v = foreach ($k in $script:Manifests.Keys) { (Get-Manifest $script:Manifests[$k]).ModuleVersion }
        @($v | Sort-Object -Unique).Count | Should -Be 1
    }
}

Describe 'Shared/' {
    It 'holds no session state' {
        foreach ($f in Get-ChildItem (Join-Path $script:Repo 'Shared') -Filter '*.ps1') {
            Get-Content $f.FullName -Raw | Should -Not -Match '\$script:DFSession' -Because $f.Name
        }
    }
}
