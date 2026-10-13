BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # Dot-sources a shipped companion the way Invoke-DFToolCompanion does, with $DFCurrentTool set.
    function script:Import-Companion([string]$Tool) {
        $DFCurrentTool = ConvertTo-DFToolRecord (Get-Content (Join-Path $PSScriptRoot "../Tools/$Tool.json") -Raw | ConvertFrom-Json)
        . (Join-Path $PSScriptRoot "../Tools/$Tool.ps1")
    }
    # Global stand-ins for native tools: each records "<name> <args>" and returns Lines["<name> <first arg>"].
    function script:Set-NativeStub([string[]]$Name) {
        foreach ($n in $Name) {
            $stubName = $n
            Set-Item "function:global:$stubName" -Value ({
                $global:DFTestNative.Calls.Add("$stubName $($args -join ' ')")
                $global:DFTestNative.Where.Add((Get-Location).ProviderPath)
                $global:DFTestNative.Lines["$stubName $($args[0])"]
            }.GetNewClosure())
        }
    }
}

Describe 'Companion pickers' {
    BeforeEach {
        Set-DFTestXdg
        $global:DFTestNative = @{
            Calls = [System.Collections.Generic.List[string]]::new()
            Where = [System.Collections.Generic.List[string]]::new()
            Lines = @{}
        }
        $script:Calls = $global:DFTestNative.Calls
        $script:Lines = $global:DFTestNative.Lines
        # fzf answers with the next reply in the queue; each call's items and arguments are kept.
        $script:Replies = [System.Collections.Generic.Queue[object]]::new()
        $script:Fzf = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-DFFzf {
            $script:Fzf.Add([pscustomobject]@{ Items = @($InputItems); Args = ($FzfArgs -join ' ') })
            if ($script:Replies.Count) { $script:Replies.Dequeue() }
        }
        Mock Write-Host { }
        Mock Write-Warning { }
    }
    AfterEach {
        Remove-DFTestGlobal -Function jq, fd, glow, bw, npm, pnpm, bun, yarn, Select-JsonPath, Read-MarkdownFile,
            Select-UvVenv, Select-NpmScript, Select-BwItem, Invoke-DFPicker -Alias fjq, fgl, fvenv, fns, fbw
        Remove-Variable -Name DFTestNative, DFTestActivated -Scope Global -ErrorAction Ignore
        Restore-DFTestXdg
    }

    Context 'fjq (jq)' {
        BeforeEach {
            Set-NativeStub jq, fd
            $script:Lines['jq .name | ascii_upcase'] = '"ANN"'
            $script:Json = Join-Path $TestDrive 'my data.json'
            Set-Content -LiteralPath $script:Json -Value '{ "name": "ann" }'
            Import-Companion jq
        }
        It 'runs the filter typed in fzf on the file, and returns its output' {
            $script:Replies.Enqueue('.name | ascii_upcase')
            fjq $script:Json | Should -Be '"ANN"'
            $script:Calls | Should -Be @("jq .name | ascii_upcase $($script:Json)")
            $script:Fzf[0].Args | Should -BeLike '*--disabled*--query .*enter:print-query*'
            $script:Fzf[0].Args | Should -BeLike "*--preview jq -C {q} ""$($script:Json)""*"
        }
        It 'picks a JSON file first when given no path' {
            Push-Location $TestDrive
            try {
                $script:Lines['fd --type'] = 'my data.json'
                $script:Replies.Enqueue('my data.json'); $script:Replies.Enqueue('.')
                $null = fjq
                $script:Fzf[0].Items | Should -Be @('my data.json')
                $script:Calls | Should -Contain "jq . $($script:Json)"
            } finally { Pop-Location }
        }
        It 'runs nothing when fzf is cancelled' {
            fjq $script:Json | Should -BeNullOrEmpty
            $script:Calls | Should -BeNullOrEmpty
        }
        It 'warns about a file that does not exist' {
            fjq (Join-Path $TestDrive 'nope.json')
            Should -Invoke Write-Warning -Times 1
            Should -Invoke Invoke-DFFzf -Times 0
        }
    }

    Context 'fgl (glow)' {
        BeforeEach {
            Import-Companion glow
            Set-NativeStub glow, fd
            Set-DFSessionTheme -Name glow -Theme ([pscustomobject]@{ Value = 'dracula' })
            # Read-MarkdownFile is a closure, so it reaches a global Invoke-DFPicker, not the mock.
            Set-Item function:global:Invoke-DFPicker -Value {
                param([scriptblock]$List, [string]$Preview, [string]$Header, [scriptblock]$Action)
                $global:DFTestNative.Preview = $Preview
                $global:DFTestNative.Items = @(& $List)
                & $Action $global:DFTestNative.Items[0]
            }
        }
        It 'lists markdown files under the path and opens the chosen one in glow''s pager' {
            $script:Lines['fd --type'] = 'docs\guide one.md'
            fgl $TestDrive
            $script:Calls[0] | Should -Be "fd --type f --extension md . $TestDrive"
            $script:Calls | Should -Contain 'glow -p docs\guide one.md'
            $global:DFTestNative.Preview | Should -BeLike 'glow.exe -s "dracula" {}'
        }
        It 'falls back to Get-ChildItem without fd' {
            # fgl is a closure (no mocks reach it) and this machine may have a real fd: hide both.
            Remove-DFTestGlobal -Function fd
            New-Item -ItemType File -Path (Join-Path $TestDrive 'notes/a.md') -Force | Out-Null
            $savedPath = $Env:PATH
            try { $Env:PATH = ''; fgl $TestDrive } finally { $Env:PATH = $savedPath }
            $global:DFTestNative.Items | Should -Contain (Join-Path $TestDrive 'notes/a.md')
        }
    }

    Context 'fvenv (uv)' {
        BeforeEach {
            $script:Venv = Join-Path $TestDrive 'my proj/.venv'
            $bin = if ($IsWindows) { 'Scripts' } else { 'bin' }
            New-Item -ItemType Directory -Path (Join-Path $script:Venv $bin) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Venv 'pyvenv.cfg') -Value 'version = 3.13.1'
            Set-Content -LiteralPath (Join-Path $script:Venv "$bin/Activate.ps1") -Value '$global:DFTestActivated = $PSScriptRoot'
            Import-Companion uv
        }
        It 'activates the chosen venv' {
            $cfg = Join-Path $script:Venv 'pyvenv.cfg'
            $script:Replies.Enqueue($cfg)
            fvenv $TestDrive
            $script:Fzf[0].Items | Should -Be @($cfg)
            $global:DFTestActivated | Should -Be (Join-Path $script:Venv $(if ($IsWindows) { 'Scripts' } else { 'bin' }))
        }
        It 'searches the current folder by default' {
            Push-Location (Join-Path $TestDrive 'my proj')
            try { fvenv } finally { Pop-Location }
            $script:Fzf[0].Items | Should -Be @(Join-Path $script:Venv 'pyvenv.cfg')
        }
        It 'warns when the chosen venv has no Activate.ps1' {
            Remove-Item (Join-Path $script:Venv '*/Activate.ps1')
            $script:Replies.Enqueue((Join-Path $script:Venv 'pyvenv.cfg'))
            fvenv $TestDrive
            Should -Invoke Write-Warning -Times 1
            $global:DFTestActivated | Should -BeNullOrEmpty
        }
    }

    Context 'fns (npm)' {
        BeforeEach {
            Set-NativeStub npm, pnpm, bun, yarn
            $script:App = Join-Path $TestDrive 'app'
            New-Item -ItemType Directory -Path (Join-Path $script:App 'src') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:App 'package.json') -Value '{ "scripts": { "build": "tsc -p .", "test": "vitest" } }'
            Import-Companion npm
        }
        It 'runs the chosen script from the package folder with npm, found from a subfolder' {
            $script:Replies.Enqueue("build`ttsc -p .")
            Push-Location (Join-Path $script:App 'src')
            try { fns } finally { Pop-Location }
            $script:Fzf[0].Items | Should -Be @("build`ttsc -p .", "test`tvitest")
            $script:Calls | Should -Be @('npm run build')
            $global:DFTestNative.Where[0] | Should -Be $script:App
        }
        It 'uses the manager whose lockfile is next to package.json' {
            Set-Content -LiteralPath (Join-Path $script:App 'pnpm-lock.yaml') -Value ''
            $script:Replies.Enqueue("test`tvitest")
            Push-Location $script:App
            try { fns } finally { Pop-Location }
            $script:Calls | Should -Be @('pnpm run test')
        }
        It 'warns, without opening fzf, when there is no package.json' {
            Push-Location $TestDrive
            try { fns } finally { Pop-Location }
            Should -Invoke Write-Warning -Times 1
            Should -Invoke Invoke-DFFzf -Times 0
        }
    }

    Context 'fbw (bitwarden)' {
        BeforeEach {
            Set-NativeStub bw
            $script:Lines['bw status'] = '{"status":"unlocked"}'
            $script:Lines['bw list'] = '[{"id":"i1","name":"GitHub","type":1,"login":{"username":"ann"}},{"id":"i2","name":"Recovery codes","type":2}]'
            $script:Lines['bw get'] = 'S3cret!'
            Mock Set-Clipboard { }
            Mock Start-Process { $script:Clear = @{ FilePath = $FilePath; ArgumentList = @($ArgumentList); WindowStyle = $WindowStyle } }
            Import-Companion bitwarden
        }
        It 'copies the chosen login''s password, and nothing secret reaches the output or the list' {
            $script:Replies.Enqueue("GitHub`tann`ti1")
            $out = @(fbw -Type login)
            $script:Fzf[0].Items | Should -Be @("GitHub`tann`ti1")
            $script:Calls | Should -Contain 'bw get password i1'
            Should -Invoke Set-Clipboard -Times 1 -ParameterFilter { $Value -eq 'S3cret!' }
            ($out -join ' ') | Should -Not -BeLike '*S3cret*'
            ($script:Fzf.Args -join ' ') | Should -Not -BeLike '*S3cret*'
        }
        It 'clears the clipboard from a separate hidden process that holds only a hash of the password' {
            $script:Replies.Enqueue("GitHub`tann`ti1")
            fbw
            $script:Clear.WindowStyle | Should -Be 'Hidden'
            $encoded = $script:Clear.ArgumentList[$script:Clear.ArgumentList.IndexOf('-EncodedCommand') + 1]
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            ($script:Clear.ArgumentList -join ' ') + $command | Should -Not -BeLike '*S3cret*'
            # Run the clear script here, with the clipboard and the wait mocked.
            Mock Start-Sleep { }
            Mock Get-Clipboard { "S3cret!`r`n" }
            & ([scriptblock]::Create($command))
            Should -Invoke Set-Clipboard -Times 1 -ParameterFilter { $null -eq $Value }
            Mock Get-Clipboard { 'something the user copied' }
            & ([scriptblock]::Create($command))
            Should -Invoke Set-Clipboard -Times 1 -ParameterFilter { $null -eq $Value }
        }
        It 'says how to unlock a locked vault, without listing anything' {
            $script:Lines['bw status'] = '{"status":"locked"}'
            fbw
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*bw unlock*' }
            $script:Calls | Should -Not -Contain 'bw list items'
        }
        It 'warns when the chosen item has no password' {
            $script:Lines['bw get'] = $null
            $script:Replies.Enqueue("Recovery codes`t`ti2")
            fbw
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*Recovery codes*no password*' }
            Should -Invoke Set-Clipboard -Times 0
        }
    }
}
