BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # Builds a shipped record's declarative pickers as global functions.
    function script:Use-ShippedPicker([string]$Tool) {
        $record = ConvertTo-DFToolRecord (Get-Content (Join-Path $PSScriptRoot "../Tools/$Tool.json") -Raw | ConvertFrom-Json)
        New-DFToolPickerFunction -Tool $record
        $record
    }
    $script:Natives = 'rustup', 'chezmoi', 'docker', 'gh'
    $script:Pickers = 'Select-RustupToolchain', 'Edit-DotFile', 'Select-DockerContainer', 'Select-DockerImage', 'Select-GHPr', 'Select-GHIssue'
    $script:Aliases = 'frtc', 'czf', 'fdc', 'fdi', 'fpr', 'fgi'
}

Describe 'Legacy pickers declared in the tool records' {
    BeforeEach {
        # The stubs run outside this file's script scope, so they share state through one global.
        $global:DFTestNative = @{ Calls = [System.Collections.Generic.List[string]]::new(); Lines = @{} }
        $script:Calls = $global:DFTestNative.Calls
        $script:Lines = $global:DFTestNative.Lines
        foreach ($n in $script:Natives) {
            $name = $n
            Set-Item "function:global:$name" -Value ({
                $global:DFTestNative.Calls.Add("$name $($args -join ' ')")
                $global:DFTestNative.Lines["$name $($args[0])"]
            }.GetNewClosure())
        }
        # The generated picker is a global function, so a global stand-in (not a Mock) is what it calls.
        # It runs the record's own list, parse and action, choosing line $global:DFTestNative.Pick.
        $global:DFTestNative.Pick = 0
        Set-Item function:global:Invoke-DFPicker -Value {
            param([scriptblock]$List, [string]$Preview, [string]$PreviewWindow, [switch]$Ansi, [string]$Header, [scriptblock]$Parse, [scriptblock]$Action)
            $global:DFTestNative.Preview = $Preview
            $line = @(& $List)[$global:DFTestNative.Pick]
            $value = if ($Parse) { $line | ForEach-Object $Parse } else { $line }
            if ($Action) { & $Action $value } else { $value }
        }
    }
    AfterEach {
        Remove-DFTestGlobal -Function ($script:Natives + $script:Pickers + 'Invoke-DFPicker') -Alias $script:Aliases
        Remove-Variable -Name DFTestNative -Scope Global -ErrorAction Ignore
    }

    It 'frtc makes the chosen toolchain the default, without its markers' {
        $script:Lines['rustup toolchain'] = 'nightly-x86_64-pc-windows-msvc', 'stable-x86_64-pc-windows-msvc (active, default)'
        $global:DFTestNative.Pick = 1
        $null = Use-ShippedPicker rustup
        frtc
        $script:Calls | Should -Contain 'rustup default stable-x86_64-pc-windows-msvc'
    }
    It 'czf lists managed files as absolute paths and edits the chosen one' {
        $script:Lines['chezmoi managed'] = 'C:\Users\me\My Docs\.gitconfig'
        $null = Use-ShippedPicker chezmoi
        czf
        $script:Calls[0] | Should -Be 'chezmoi managed --path-style absolute --include files'
        $script:Calls | Should -Contain 'chezmoi edit C:\Users\me\My Docs\.gitconfig'
    }
    It 'fdc opens a shell in the chosen running container, bash when it has one' {
        $script:Lines['docker ps'] = "a1b2c3`tweb`tnginx:1.27`tUp 2 hours"
        $null = Use-ShippedPicker docker
        fdc
        $script:Calls[0] | Should -BeLike 'docker ps --format *'
        $script:Calls[0] | Should -Not -BeLike '*--all*'
        $script:Calls | Should -Contain "docker exec -it a1b2c3 sh -c command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        $global:DFTestNative.Preview | Should -Be 'docker logs --tail 50 {1}'
    }
    It 'fdi outputs repo:tag, or the ID of an untagged image' {
        $script:Lines['docker images'] = "alpine:3.20`tdef456`t8MB", "<none>:<none>`tabc123`t1GB"
        $null = Use-ShippedPicker docker
        fdi | Should -Be 'alpine:3.20'
        $global:DFTestNative.Pick = 1
        fdi | Should -Be 'abc123'
        $global:DFTestNative.Preview | Should -Be 'docker image history {2}'
    }
    It 'fpr checks out the chosen pull request' {
        $script:Lines['gh pr'] = '[{"number":42,"title":"Fix it","author":{"login":"ann"}}]'
        $null = Use-ShippedPicker gh
        fpr
        $script:Calls | Should -Contain 'gh pr checkout 42'
        $global:DFTestNative.Preview | Should -Be 'gh pr view {1}'
    }
    It 'fgi opens the chosen issue in the browser' {
        $script:Lines['gh issue'] = '[{"number":7,"title":"Broken"}]'
        $null = Use-ShippedPicker gh
        fgi
        $script:Calls | Should -Contain 'gh issue view 7 --web'
        $global:DFTestNative.Preview | Should -Be 'gh issue view {1}'
    }
}
