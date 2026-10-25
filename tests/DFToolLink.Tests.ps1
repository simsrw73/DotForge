BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

# Links from an XDG location to a tool's existing data (docs/superpowers/specs/2026-10-25-link-existing-design.md).
# Every path is under $TestDrive; removing a link must never touch what it points to.
Describe 'DotForge links' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive "links-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $script:Target = Join-Path $script:Root 'real'
        New-Item -ItemType Directory -Force (Join-Path $script:Target 'sub') | Out-Null
        Set-Content (Join-Path $script:Target 'sub' 'data.txt') 'keep me'
        $script:Link = Join-Path $script:Root 'xdg' 'tool'
    }

    It 'links a folder with a junction that shows the target''s files' {
        $r = New-DFToolLink -Path $script:Link -Target $script:Target
        $r.Made | Should -BeTrue
        $r.Note | Should -BeNullOrEmpty
        Get-DFToolLinkTarget -Path $script:Link | Should -Be (ConvertTo-DFPath $script:Target)
        Get-Content (Join-Path $script:Link 'sub' 'data.txt') | Should -Be 'keep me'
    }
    It 'leaves an existing link to the same target alone' {
        $null = New-DFToolLink -Path $script:Link -Target $script:Target
        (New-DFToolLink -Path $script:Link -Target $script:Target).Made | Should -BeTrue
        Get-DFToolLinkTarget -Path $script:Link | Should -Be (ConvertTo-DFPath $script:Target)
    }
    It 'refuses to replace a folder with files in it' {
        New-Item -ItemType File -Force (Join-Path $script:Link 'mine.txt') | Out-Null
        { New-DFToolLink -Path $script:Link -Target $script:Target } | Should -Throw
    }
    It 'replaces an empty folder (one DotForge created earlier)' {
        New-Item -ItemType Directory -Force (Join-Path $script:Link 'empty-sub') | Out-Null
        (New-DFToolLink -Path $script:Link -Target $script:Target).Made | Should -BeTrue
        Get-DFToolLinkTarget -Path $script:Link | Should -Be (ConvertTo-DFPath $script:Target)
    }
    It 'links a single file only with Developer Mode, otherwise says how' {
        $file = Join-Path $script:Target 'sub' 'data.txt'
        $fileLink = Join-Path $script:Root 'xdg' 'tool.conf'
        Mock Test-DFDeveloperMode { $false }
        $r = New-DFToolLink -Path $fileLink -Target $file
        $r.Made | Should -BeFalse
        $r.Note | Should -BeLike '*Developer Mode*'
        Test-Path $fileLink | Should -BeFalse
        Mock Test-DFDeveloperMode { $true }
        Mock New-DFFileSymlink { }
        $null = New-DFToolLink -Path $fileLink -Target $file
        Should -Invoke New-DFFileSymlink -Times 1 -Exactly -ParameterFilter { $Path -eq (ConvertTo-DFPath $fileLink) -and $Target -eq (ConvertTo-DFPath $file) }
    }
    It 'removes the link and never the target''s files' {
        $null = New-DFToolLink -Path $script:Link -Target $script:Target
        Remove-DFToolLink -Path $script:Link
        Test-Path $script:Link | Should -BeFalse
        Get-Content (Join-Path $script:Target 'sub' 'data.txt') | Should -Be 'keep me'
    }
    It 'finds and removes a link whose target is gone' {
        $null = New-DFToolLink -Path $script:Link -Target $script:Target
        [IO.Directory]::Delete($script:Target, $true)
        Get-DFToolLinkTarget -Path $script:Link | Should -Be (ConvertTo-DFPath $script:Target)
        Remove-DFToolLink -Path $script:Link
        [IO.Directory]::Exists($script:Link) -or [IO.File]::Exists($script:Link) | Should -BeFalse
        Get-DFToolLinkTarget -Path $script:Link | Should -BeNullOrEmpty
    }
    It 'leaves a real folder alone' {
        New-Item -ItemType Directory -Force $script:Link | Out-Null
        Set-Content (Join-Path $script:Link 'mine.txt') 'x'
        Get-DFToolLinkTarget -Path $script:Link | Should -BeNullOrEmpty
        Remove-DFToolLink -Path $script:Link
        Test-Path (Join-Path $script:Link 'mine.txt') | Should -BeTrue
    }
}
