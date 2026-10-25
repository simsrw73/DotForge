BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Remove-DFTool' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig @{ Tools = @('fzf', 'PSFzf', 'glow') }
        $script:Db = @{
            scoop = Rec '{ "name": "scoop", "executable": "scoop.cmd", "packages": { "winget": "ScoopInstaller.Scoop" }, "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "remove": ["scoop","uninstall","{id}"], "list": "Get-FakeScoopInstalled" } }'
            fzf   = Rec '{ "name": "fzf", "executable": "fzf.exe", "packages": { "scoop": "fzf" } }'
            PSFzf = Rec '{ "name": "PSFzf", "executable": "PSFzf", "type": "module", "requires": ["fzf"], "packages": { "scoop": "psfzf" } }'
            glow  = Rec '{ "name": "glow", "executable": "glow.exe", "xdg": { "method": "env", "vars": { "GLOW_X": "${XDG_CONFIG_HOME}/glow" } }, "packages": { "scoop": "glow" }, "setup": { "seed": { "${XDG_CONFIG_HOME}/glow/glow.yml": "glow/glow.yml" } } }'
        }
        Mock Import-DFToolDb { $script:Db }
        Mock Get-DFToolStatus { foreach ($n in 'fzf', 'PSFzf', 'glow') { New-DFToolStatus -Name $n -State Active } }
        Mock Find-DFToolSource {
            $m = $script:Db.scoop
            $id = @($Tool.packages.PSObject.Properties.Value)[0]
            [pscustomobject]@{ Tool = $Tool.name; Source = 'scoop'; Manager = $m; Block = $m.installs[0]; Id = $id; Installed = '1'; Detail = 'via scoop' }
        }
        Mock Get-DFManagerInstalled { }
        Mock Import-DFManagerOps { }
        Mock Test-DFToolAvailable { $true }
        $script:Removed = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-DFManagerBatch { foreach ($i in $Ids) { $script:Removed.Add($i); [pscustomobject]@{ Id = $i; ExitCode = 0; Output = '' } } }
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }
    AfterEach { Set-DFTestConfig $null; Restore-DFTestXdg }

    It 'removes a tool nothing requires, through the manager it came from' {
        $r = Remove-DFTool -Name glow -Confirm:$false
        $r.Result | Should -Be 'Removed'
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly -ParameterFilter { $Operation -eq 'remove' -and $Manager.name -eq 'scoop' -and ($Ids -join ',') -eq 'glow' }
    }
    It "gives the remove command the tool's variables" {
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:DFSessionStatus['glow'] = New-DFToolStatus -Name glow -State Active -RequestedBy Tools
        $null = Remove-DFTool -Name glow -Confirm:$false
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly -ParameterFilter { $Environment -and $Environment.Contains('GLOW_X') }
    }
    It 'refuses a tool an active tool requires, naming it' {
        $r = Remove-DFTool -Name fzf -Confirm:$false
        $r.Result | Should -Be 'Refused'
        $r.Detail | Should -Be 'required by PSFzf: use -IncludeDependents to remove them too, or -Force'
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'removes it anyway with -Force' {
        (Remove-DFTool -Name fzf -Force -Confirm:$false).Result | Should -Be 'Removed'
        $script:Removed | Should -Be @('fzf')
    }
    It 'removes dependents first with -IncludeDependents' {
        $r = @(Remove-DFTool -Name fzf -IncludeDependents -Confirm:$false)
        $script:Removed | Should -Be @('psfzf', 'fzf')
        $r.Tool | Should -Be @('PSFzf', 'fzf')
    }
    It 'removes a tool and its dependent named together, dependent first, without -IncludeDependents' {
        $r = @(Remove-DFTool -Name fzf, PSFzf -Confirm:$false)
        $r.Result | Should -Be @('Removed', 'Removed')
        $script:Removed | Should -Be @('psfzf', 'fzf')
    }
    It 'removes nothing with -WhatIf' {
        $null = Remove-DFTool -Name fzf -IncludeDependents -WhatIf
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'says a tool that is not installed anywhere is not installed, without calling a manager' {
        Mock Find-DFToolSource { [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Id = $null; Installed = $null; Detail = 'not installed through any of: scoop' } }
        $r = Remove-DFTool -Name glow -Confirm:$false
        $r.Result | Should -Be 'NotInstalled'
        $r.Detail | Should -Be 'not installed through any of: scoop'
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'refuses a manager that still has packages installed, even with -IncludeDependents' {
        Mock Get-DFManagerInstalled { [pscustomobject]@{ Id = 'fzf'; Installed = '1'; Available = $null }; [pscustomobject]@{ Id = 'glow'; Installed = '1'; Available = $null } }
        $r = Remove-DFTool -Name scoop -IncludeDependents -Confirm:$false
        $r.Result | Should -Be 'Refused'
        $r.Detail | Should -Be 'scoop still has packages installed: fzf, glow (use -Force to remove it anyway)'
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'removes a manager with -Force, and nothing it installed' {
        Mock Get-DFManagerInstalled { [pscustomobject]@{ Id = 'fzf'; Installed = '1'; Available = $null } }
        $null = Remove-DFTool -Name scoop -Force -IncludeDependents -Confirm:$false
        $script:Removed | Should -Be @('ScoopInstaller.Scoop')
    }
    It 'refuses a manager that cannot list what it installed, unless -Force' {
        $script:Db.fnm = Rec '{ "name": "fnm", "executable": "fnm.exe", "packages": { "scoop": "fnm" }, "installs": { "from": "fnm", "install": ["fnm","install","{id}"] } }'
        $r = Remove-DFTool -Name fnm -Confirm:$false
        $r.Result | Should -Be 'Refused'
        $r.Detail | Should -Be "can't tell what fnm has installed (use -Force to remove it anyway)"
        (Remove-DFTool -Name fnm -Force -Confirm:$false).Result | Should -Be 'Removed'
    }
    It 'marks the tool Missing and reports what is left behind' {
        $seeded = Join-Path $Env:XDG_CONFIG_HOME 'glow/glow.yml'
        New-Item -ItemType File -Path $seeded -Force | Out-Null
        Complete-DFToolSetup -Name glow -Actions @(@{ type = 'gitConfigInclude'; path = 'C:\x\glow.gitconfig' })
        $script:DFSessionStatus = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:DFSessionStatus['glow'] = New-DFToolStatus -Name glow -State Active -RequestedBy Tools
        $null = Remove-DFTool -Name glow -Confirm:$false
        $script:DFSessionStatus['glow'].State | Should -Be 'Missing'
        $script:DFSessionStatus['glow'].Detail | Should -Be 'removed by Remove-DFTool'
        $text = $script:Lines -join "`n"
        $text | Should -BeLike "*$seeded*"
        $text | Should -BeLike '*change its setup made: gitConfigInclude path=C:\x\glow.gitconfig*'
        $text | Should -BeLike "*remove 'glow' from Tools in your profile*"
        $text | Should -BeLike '*new shell*'
    }
    It 'keeps the setup record, so a reinstall does not run setup again' {
        Complete-DFToolSetup -Name glow
        $null = Remove-DFTool -Name glow -Confirm:$false
        (Get-DFToolSetupState).PSObject.Properties['glow'] | Should -Not -BeNullOrEmpty
    }
}
