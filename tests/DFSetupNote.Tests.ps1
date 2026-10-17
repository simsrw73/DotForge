BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    function script:New-NoteTool([string]$Json, [hashtable]$Files = @{}) {
        $dir = Join-Path $TestDrive "nt-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory (Join-Path $dir 'nt') -Force | Out-Null
        Set-Content (Join-Path $dir 'nt' 'c.conf') 'default' -NoNewline
        foreach ($k in $Files.Keys) {
            $path = Join-Path $dir $k
            New-Item -ItemType Directory (Split-Path $path) -Force | Out-Null
            Set-Content $path $Files[$k] -NoNewline
        }
        Set-Content (Join-Path $dir 'nt.json') $Json
        $dir
    }
    $script:NotesJson = '{ "name": "nt", "executable": "nt.exe", "setup": {
        "seed": { "${XDG_CONFIG_HOME}/nt/c.conf": "nt/c.conf" },
        "notes": [ { "text": "always" }, { "text": "you had a config", "ifFile": "${XDG_CONFIG_HOME}/nt/c.conf" } ] } }'
}

Describe 'setup notes' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'nt') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
        Mock Write-Host { }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'records a declared note with the setup and shows it once' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always')
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'DotForge: nt: always' }
    }
    It 'evaluates a note''s condition before the seeds are copied' {
        $tools = New-NoteTool $script:NotesJson
        $own = Join-Path $Env:XDG_CONFIG_HOME 'nt' 'c.conf'
        New-Item -ItemType Directory (Split-Path $own) -Force | Out-Null
        Set-Content $own 'mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always', 'you had a config')
        Get-Content $own -Raw | Should -Be 'mine'
    }
    It 'does not show the note again on a later load, but keeps it in the status' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Reset-DFTestSession
        Mock Write-Host { }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        # Only the first load printed it.
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
        (Get-DFToolStatus nt).Detail | Should -Match 'setup note: always'
    }
    It 'shows and records nothing for a tool in SkipSetup' {
        $tools = New-NoteTool $script:NotesJson
        Start-DFSession -Config @{ Tools = @('nt'); SkipSetup = @('nt') } -ToolsPath $tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['nt'] | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
    }
    It 'records a note a setup script adds' {
        $tools = New-NoteTool '{ "name": "nt", "executable": "nt.exe" }' @{
            'nt.setup.ps1' = "Add-DFToolSetupNote -Name nt -Text 'from the script'`nComplete-DFToolSetup -Name nt"
        }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('from the script')
    }
    It 'records the seeds with the setup when a setup script completes it' {
        $json = $script:NotesJson
        $tools = New-NoteTool $json @{ 'nt.setup.ps1' = "Complete-DFToolSetup -Name nt -Actions @(@{ type = 'own' })" }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        @((Get-DFToolSetupState).nt.actions.type) | Should -Be @('seedConfig', 'own')
    }
    It 'does not mistake its own seeded file for the user''s when setup runs again' {
        $tools = New-NoteTool $script:NotesJson @{ 'nt.setup.ps1' = 'Complete-DFToolSetup -Name nt' }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Invoke-DFToolSetup -Name nt -ToolsPath $tools -Confirm:$false
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always')
    }
    It 'still notes the user''s own file when setup runs again' {
        $tools = New-NoteTool $script:NotesJson @{ 'nt.setup.ps1' = 'Complete-DFToolSetup -Name nt' }
        $own = Join-Path $Env:XDG_CONFIG_HOME 'nt' 'c.conf'
        New-Item -ItemType Directory (Split-Path $own) -Force | Out-Null
        Set-Content $own 'mine' -NoNewline
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Invoke-DFToolSetup -Name nt -ToolsPath $tools -Confirm:$false
        @((Get-DFToolSetupState).nt.notes) | Should -Be @('always', 'you had a config')
    }
    It 'drops the notes of a setup that fails, so the retry starts clean' {
        $tools = New-NoteTool '{ "name": "nt", "executable": "nt.exe" }' @{
            'nt.setup.ps1' = "Add-DFToolSetupNote -Name nt -Text 'half done'`nthrow 'boom'"
        }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        (Get-DFToolSetupState).PSObject.Properties['nt'] | Should -BeNullOrEmpty
        Get-DFPendingSetupNote -Name nt | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like 'DotForge: nt:*' }
    }
}

Describe 'seed sources with {theme}' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession; Set-DFTestConfig $null
        # $TestDrive (and so the XDG folders) lasts the whole Describe: start each test clean.
        Remove-Item (Get-DFToolSetupStatePath), (Join-Path $Env:XDG_CONFIG_HOME 'nt') -Recurse -Force -ErrorAction Ignore
        Mock Test-DFToolAvailable { $true }
        Mock Write-DFConflictNotice { }
    }
    AfterEach { Restore-DFTestXdg; Set-DFTestConfig $null }

    It 'copies the theme''s own file, following Theme' {
        $json = '{ "name": "nt", "executable": "nt.exe", "theme": { "key": "NtTheme", "default": "one", "files": "nt" },
                   "setup": { "seed": { "${XDG_CONFIG_HOME}/nt/conf.json": "{theme}" } } }'
        $tools = New-NoteTool $json @{ 'nt/one.json' = '{"n":1}'; 'nt/two.json' = '{"n":2}' }
        Start-DFSession -Config @{ Tools = @('nt'); Theme = 'two' } -ToolsPath $tools 3>$null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'nt' 'conf.json') -Raw | Should -Be '{"n":2}'
    }
    It 'copies a file inside a theme folder' {
        $json = '{ "name": "nt", "executable": "nt.exe", "theme": { "key": "NtTheme", "default": "one", "files": "nt" },
                   "setup": { "seed": { "${XDG_CONFIG_HOME}/nt/config.toml": "{theme}/config.toml" } } }'
        $tools = New-NoteTool $json @{ 'nt/one/config.toml' = 'theme = "one"' }
        Start-DFSession -Config @{ Tools = @('nt') } -ToolsPath $tools 3>$null
        Get-Content (Join-Path $Env:XDG_CONFIG_HOME 'nt' 'config.toml') -Raw | Should -Be 'theme = "one"'
    }
}

Describe 'setup.notes schema' {
    BeforeAll {
        function script:Get-NoteSchemaError($Notes) {
            $tool = [pscustomobject]@{ name = 't'; executable = 't.exe'; setup = [pscustomobject]@{ notes = $Notes } }
            "$((Test-DFToolSchema -Tool $tool).Errors)"
        }
    }
    It 'accepts notes with text and optional conditions' {
        Get-NoteSchemaError @([pscustomobject]@{ text = 'x' }, [pscustomobject]@{ text = 'y'; ifFile = 'a'; unlessFile = 'b' }) | Should -BeNullOrEmpty
    }
    It 'accepts a single note (a one-element array)' {
        Get-NoteSchemaError @([pscustomobject]@{ text = 'x' }) | Should -BeNullOrEmpty
    }
    It 'rejects a note without text, a non-string condition, or a non-array' {
        Get-NoteSchemaError @([pscustomobject]@{ ifFile = 'a' }) | Should -Match 'setup\.notes'
        Get-NoteSchemaError @([pscustomobject]@{ text = 'x'; ifFile = 3 }) | Should -Match 'setup\.notes'
        Get-NoteSchemaError 'x' | Should -Match 'setup\.notes'
    }
}
