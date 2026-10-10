#Requires -Version 7.2
# What DotForge and its development need, declared once and kept in step:
# the manifests (users), #Requires lines, and build/requirements.psd1 (development).

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent
    $script:manifestPaths = @(
        Join-Path $repo 'DotForge.psd1'
        Get-ChildItem (Join-Path $repo 'Modules') -Filter '*.psd1' -Recurse | ForEach-Object FullName
    ) | ForEach-Object { @{ Manifest = [IO.Path]::GetRelativePath($repo, $_) -replace '\\', '/'; Path = $_ } }
}

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Core = Import-PowerShellDataFile (Join-Path $script:Repo 'DotForge.psd1')
    $script:DevModules = Import-PowerShellDataFile (Join-Path $script:Repo 'build' 'requirements.psd1')
    # Every tracked script. git ls-files never walks ignored folders, which a recursive
    # listing does (a large ignored clone made this test take minutes).
    $script:Scripts = @(git -C $script:Repo ls-files '*.ps1' '*.psm1' | ForEach-Object { Get-Item (Join-Path $script:Repo $_) })
}

Describe 'Declared requirements' {
    It '<Manifest> needs the same PowerShell as DotForge.psd1' -ForEach $script:manifestPaths {
        $m = Import-PowerShellDataFile $Path
        $m.PowerShellVersion | Should -Be $script:Core.PowerShellVersion
        $m.CompatiblePSEditions | Should -Be $script:Core.CompatiblePSEditions
    }

    It 'every #Requires -Version line matches the manifest''s PowerShellVersion' {
        $wrong = foreach ($f in $script:Scripts) {
            foreach ($line in (Get-Content $f.FullName -TotalCount 5)) {
                if ($line -match '^#Requires -Version (\S+)' -and $Matches[1] -ne $script:Core.PowerShellVersion) {
                    "$([IO.Path]::GetRelativePath($script:Repo, $f.FullName)): $line"
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'tags the Gallery package for PowerShell (Core) on Windows' {
        $script:Core.PrivateData.PSData.Tags | Should -Contain 'PSEdition_Core'
        $script:Core.PrivateData.PSData.Tags | Should -Contain 'Windows'
    }

    It 'lists in build/requirements.psd1 every Gallery module the tests and build scripts require' {
        # A literal Import-Module without -ErrorAction is a requirement; one with
        # -ErrorAction (e.g. Scoop, "so *-ScoopApp exist to mock") is optional.
        $missing = foreach ($f in $script:Scripts | Where-Object { $_.FullName -match '[\\/](tests|build)[\\/]' }) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true)
            foreach ($call in $calls) {
                $elements = $call.CommandElements
                if ($elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -like 'ErrorAction*' }) { continue }
                $name = $elements | Select-Object -Skip 1 | Where-Object {
                    $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } | Select-Object -First 1
                if (-not $name -or $name.Value -match '[\\/]|\.psd?1$|^DotForge') { continue }
                if (-not $script:DevModules.ContainsKey($name.Value)) { "$($f.Name): $($name.Value)" }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'CI installs development modules only through build/Install-DFDevDependencies.ps1' {
        $workflow = Get-Content (Join-Path $script:Repo '.github' 'workflows' 'test.yml') -Raw
        $workflow | Should -Match 'build/Install-DFDevDependencies\.ps1'
        $workflow | Should -Not -Match 'Install-(PSResource|Module)'
    }
}
