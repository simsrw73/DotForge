BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:ShippedTools = Join-Path $PSScriptRoot '..' 'Tools'
}

Describe 'New-DFTool' {
    BeforeEach {
        Set-DFTestXdg
        $script:UserTools = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        Remove-Item $script:UserTools -Recurse -Force -ErrorAction Ignore
    }
    AfterEach { Restore-DFTestXdg }

    Context 'a new record' {
        It 'writes a record for a program on PATH, with its exe and description' {
            $app = @(Get-Command pwsh -CommandType Application)[0]
            $null = New-DFTool -Name mypwsh -Executable pwsh 6>$null
            $record = Get-Content (Join-Path $script:UserTools 'mypwsh.json') -Raw | ConvertFrom-Json
            $record.name | Should -Be 'mypwsh'
            $record.executable | Should -Be $app.Name
            $record.description | Should -Be ([string](Get-Item $app.Source).VersionInfo.FileDescription)
        }

        It 'finds the program by the tool name when -Executable is left out' {
            $null = New-DFTool -Name pwsh 6>$null
            (Get-Content (Join-Path $script:UserTools 'pwsh.json') -Raw | ConvertFrom-Json).executable |
                Should -Be @(Get-Command pwsh -CommandType Application)[0].Name
        }

        It 'starts tags, aliases and picker empty, and the record passes the schema' {
            $null = New-DFTool -Name pwsh 6>$null
            $record = Get-Content (Join-Path $script:UserTools 'pwsh.json') -Raw | ConvertFrom-Json
            @($record.tags).Count | Should -Be 0
            @($record.aliases.PSObject.Properties).Count | Should -Be 0
            $record.PSObject.Properties['picker'] | Should -Not -BeNullOrEmpty
            $record.picker | Should -BeNullOrEmpty
            (Test-DFToolSchema -Tool $record).Valid | Should -BeTrue
        }

        It 'makes a PowerShell module a module tool' {
            $null = New-DFTool -Name Pester 6>$null
            $record = Get-Content (Join-Path $script:UserTools 'Pester.json') -Raw | ConvertFrom-Json
            $record.type | Should -Be 'module'
            $record.executable | Should -Be 'Pester'
        }

        It 'warns, and still writes the record, when nothing by that name is installed' {
            $null = New-DFTool -Name df-no-such-tool -WarningVariable warnings 3>$null 6>$null
            "$warnings" | Should -Match 'df-no-such-tool'
            (Get-Content (Join-Path $script:UserTools 'df-no-such-tool.json') -Raw | ConvertFrom-Json).executable | Should -Be 'df-no-such-tool'
        }

        It 'adds a companion skeleton with -Companion' {
            $null = New-DFTool -Name pwsh -Companion 6>$null
            $companion = Join-Path $script:UserTools 'pwsh.ps1'
            Test-Path $companion | Should -BeTrue
            $text = Get-Content $companion -Raw
            $text | Should -Match 'DFCurrentTool'
            $text | Should -Match 'Invoke-DFPicker'
            $text | Should -Match 'Register-ArgumentCompleter'
            # Everything is commented out, so the skeleton does nothing until edited.
            { . ([scriptblock]::Create($text)) } | Should -Not -Throw
        }

        It 'outputs the files it wrote' {
            $files = @(New-DFTool -Name pwsh -Companion 6>$null)
            $files.Name | Should -Be @('pwsh.json', 'pwsh.ps1')
        }

        It 'refuses to replace an existing record without -Force' {
            $null = New-DFTool -Name pwsh 6>$null
            'keep' | Set-Content (Join-Path $script:UserTools 'pwsh.json')
            $null = New-DFTool -Name pwsh -ErrorVariable err -ErrorAction SilentlyContinue 6>$null
            "$err" | Should -Match 'already exists'
            Get-Content (Join-Path $script:UserTools 'pwsh.json') | Should -Be 'keep'
            $null = New-DFTool -Name pwsh -Force 6>$null
            Get-Content (Join-Path $script:UserTools 'pwsh.json') -Raw | Should -Not -Be "keep`r`n"
        }

        It 'writes nothing with -WhatIf' {
            $null = New-DFTool -Name pwsh -Companion -WhatIf 6>$null
            Test-Path (Join-Path $script:UserTools 'pwsh.json') | Should -BeFalse
        }

        It 'rejects a name that is not a plain file name' {
            { New-DFTool -Name '..\evil' } | Should -Throw
        }
    }

    Context '-From a shipped tool' {
        It 'copies the record, its companion and its data folder' {
            $files = @(New-DFTool -From fzf 3>$null 6>$null)
            Test-Path (Join-Path $script:UserTools 'fzf.json') | Should -BeTrue
            Test-Path (Join-Path $script:UserTools 'fzf.ps1') | Should -BeTrue
            Test-Path (Join-Path $script:UserTools 'fzf' 'catppuccin-mocha.json') | Should -BeTrue
            (Get-Content (Join-Path $script:UserTools 'fzf.json') -Raw) |
                Should -Be (Get-Content (Join-Path $script:ShippedTools 'fzf.json') -Raw)
            $files.Name | Should -Contain 'fzf.json'
        }

        It 'copies the seed files a setup block names' {
            $null = New-DFTool -From fastfetch 3>$null 6>$null
            Test-Path (Join-Path $script:UserTools 'fastfetch' 'config.jsonc') | Should -BeTrue
        }

        It 'warns that the copy no longer gets DotForge''s fixes' {
            $null = New-DFTool -From bat -WarningVariable warnings 3>$null 6>$null
            "$warnings" | Should -Match 'fixes'
        }

        It 'refuses a tool DotForge doesn''t ship' {
            $null = New-DFTool -From df-no-such-tool -ErrorVariable err -ErrorAction SilentlyContinue 3>$null 6>$null
            "$err" | Should -Match 'df-no-such-tool'
            Test-Path $script:UserTools | Should -BeFalse
        }

        It 'refuses to replace an existing copy without -Force' {
            $null = New-DFTool -From bat 3>$null 6>$null
            'keep' | Set-Content (Join-Path $script:UserTools 'bat.json')
            $null = New-DFTool -From bat -ErrorVariable err -ErrorAction SilentlyContinue 3>$null 6>$null
            "$err" | Should -Match 'already exists'
            Get-Content (Join-Path $script:UserTools 'bat.json') | Should -Be 'keep'
        }
    }
}
