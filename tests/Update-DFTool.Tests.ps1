BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function script:Rec([string]$Json) { ConvertTo-DFToolRecord ($Json | ConvertFrom-Json) }
}

Describe 'Update-DFTool' {
    BeforeEach {
        Reset-DFTestSession
        $script:Db = @{
            scoop   = Rec '{ "name": "scoop", "executable": "scoop.cmd", "installs": { "from": "scoop", "install": ["scoop","install","{id}"], "update": ["scoop","update","{id}"], "batch": true, "outdated": "Get-FakeOutdated" } }'
            winget  = Rec '{ "name": "winget", "executable": "winget.exe", "installs": { "from": "winget", "install": ["winget","install","{id}"], "update": ["winget","upgrade","{id}"], "outdated": "Get-FakeOutdated" } }'
            cargo   = Rec '{ "name": "cargo", "executable": "cargo.exe", "installs": { "from": "crates", "install": ["cargo","install","{id}"], "update": ["cargo","install","--force","{id}"] } }'
            fnm     = Rec '{ "name": "fnm", "executable": "fnm.exe", "installs": { "from": "fnm", "install": ["fnm","install","{id}"] } }'
            fzf     = Rec '{ "name": "fzf", "executable": "fzf.exe", "packages": { "scoop": "fzf" } }'
            bat     = Rec '{ "name": "bat", "executable": "bat.exe", "packages": { "winget": "sharkdp.bat" } }'
            lazygit = Rec '{ "name": "lazygit", "executable": "lazygit.exe", "packages": { "crates": "lazygit" } }'
            node    = Rec '{ "name": "node", "executable": "node.exe", "packages": { "fnm": "lts" } }'
        }
        Mock Import-DFToolDb { $script:Db }
        Mock Get-DFToolStatus { foreach ($n in 'fzf', 'bat', 'lazygit', 'node') { New-DFToolStatus -Name $n -State Active } }
        $script:Where = @{ fzf = 'scoop'; bat = 'winget'; lazygit = 'cargo'; node = 'fnm' }
        Mock Find-DFToolSource {
            $m = $script:Db[$script:Where[$Tool.name]]
            $id = (Get-DFPackageRef $Tool.packages.($m.installs[0].from)).Id
            [pscustomobject]@{ Tool = $Tool.name; Source = $m.installs[0].from; Manager = $m; Block = $m.installs[0]; Id = $id; Installed = '1.0'; Detail = "via $($m.name)" }
        }
        Mock Get-DFManagerInstalled {
            if ($Manager.name -eq 'scoop') { [pscustomobject]@{ Id = 'fzf'; Installed = '1.0'; Available = '1.1' } }
        }
        Mock Invoke-DFManagerBatch { foreach ($i in $Ids) { [pscustomobject]@{ Id = $i; ExitCode = 0; Output = 'ok' } } }
        Mock Write-Host { }
    }

    It 'shows the table for the active tools and updates nothing when called bare' {
        $rows = @(Update-DFTool)
        $rows.Tool | Should -Be @('fzf', 'bat', 'lazygit', 'node')
        ($rows | Where-Object Tool -eq fzf).State | Should -Be 'Outdated'
        ($rows | Where-Object Tool -eq fzf).Available | Should -Be '1.1'
        ($rows | Where-Object Tool -eq bat).State | Should -Be 'UpToDate'
        ($rows | Where-Object Tool -eq bat).Update | Should -Be 'up to date'
        ($rows | Where-Object Tool -eq lazygit).State | Should -Be 'Unknown'
        ($rows | Where-Object Tool -eq lazygit).Update | Should -Be 'unknown'
        $rows[0].PSObject.TypeNames | Should -Contain 'DotForge.ToolUpdate'
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'reports a runtime managed by a version manager, with what to use instead' {
        $row = Update-DFTool | Where-Object Tool -eq node
        $row.State | Should -Be 'Runtime'
        $row.Update | Should -Be 'managed by fnm: update it with fnm'
    }
    It 'reports a tool it cannot find' {
        Mock Find-DFToolSource { [pscustomobject]@{ Tool = $Tool.name; Source = $null; Manager = $null; Block = $null; Id = $null; Installed = $null; Detail = 'not installed through any of: scoop' } } -ParameterFilter { $Tool.name -eq 'fzf' }
        $row = Update-DFTool | Where-Object Tool -eq fzf
        $row.State | Should -Be 'NotFound'
        $row.Update | Should -Be 'not installed through any of: scoop'
    }
    It 'updates outdated and unknown tools with -All, and nothing else' {
        $r = @(Update-DFTool -All -Confirm:$false)
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly -ParameterFilter { $Operation -eq 'update' -and $Manager.name -eq 'scoop' -and ($Ids -join ',') -eq 'fzf' }
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly -ParameterFilter { $Manager.name -eq 'cargo' -and ($Ids -join ',') -eq 'lazygit' }
        Should -Invoke Invoke-DFManagerBatch -Times 2 -Exactly
        ($r | Where-Object Tool -eq fzf).Result | Should -Be 'Updated'
        ($r | Where-Object Tool -eq bat).Result | Should -Be 'Skipped'
        ($r | Where-Object Tool -eq node).Detail | Should -Be 'managed by fnm: update it with fnm'
    }
    It 'updates only the named tools with -Name' {
        $null = Update-DFTool -Name fzf, bat -Confirm:$false
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly
        Should -Invoke Invoke-DFManagerBatch -Times 1 -Exactly -ParameterFilter { ($Ids -join ',') -eq 'fzf' }
    }
    It 'runs nothing with -WhatIf' {
        $null = Update-DFTool -All -WhatIf
        Should -Invoke Invoke-DFManagerBatch -Times 0
    }
    It 'says everything is up to date and runs nothing when nothing has an update' {
        Mock Get-DFToolStatus { New-DFToolStatus -Name bat -State Active }
        $null = Update-DFTool -All -Confirm:$false
        Should -Invoke Invoke-DFManagerBatch -Times 0
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Everything is up to date.' }
    }
    It 'marks the tools of a failed update Failed, with the manager''s last lines' {
        Mock Invoke-DFManagerBatch { foreach ($i in $Ids) { [pscustomobject]@{ Id = $i; ExitCode = 2; Output = "line1`nERROR: network down" } } }
        $r = Update-DFTool -Name fzf -Confirm:$false
        $r.Result | Should -Be 'Failed'
        $r.Detail | Should -Be 'scoop failed: line1 / ERROR: network down'
    }
    It 'asks for admin rights for a manager that needs them' {
        $script:Db.scoop.installs[0].elevate = $true
        Mock Get-DFElevationMethod { [pscustomobject]@{ Method = 'RunAs'; Executable = $null; Detail = 'x'; Tool = $null } }
        $null = Update-DFTool -Name fzf -Confirm:$false
        Should -Invoke Invoke-DFManagerBatch -Times 1 -ParameterFilter { $Elevation.Method -eq 'RunAs' }
    }
}
