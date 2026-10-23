BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }

    # A release zip like Nerd Fonts': the Nerd Font, Mono and Propo builds of one family.
    function script:New-FontZip {
        $src = Join-Path $TestDrive "zip-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory $src -Force | Out-Null
        foreach ($file in 'HackNerdFont-Regular.ttf', 'HackNerdFont-Bold.ttf', 'HackNerdFontMono-Regular.ttf', 'HackNerdFontPropo-Regular.ttf', 'README.md') {
            Set-Content -LiteralPath (Join-Path $src $file) $file -NoNewline
        }
        $zip = "$src.zip"
        # .NET, not Compress-Archive: that cmdlet loads its module into the session for every later test file.
        [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
        $zip
    }
}

Describe 'Install-DFNerdFont' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:Zip = New-FontZip
        Mock Save-DFNerdFontArchive { $script:Zip }
        Mock Install-DFFontFile { $true }
        Mock Send-DFFontChange { }
        Mock Select-DFNerdFontName { 'Hack' }
        Mock Write-Host { }
    }

    It 'installs the Nerd Font and Mono builds of the named font, not Propo, without the picker' {
        $result = Install-DFNerdFont -Name Hack
        Should -Invoke Select-DFNerdFontName -Times 0
        Should -Invoke Install-DFFontFile -Times 3 -Exactly
        Should -Invoke Install-DFFontFile -Times 0 -ParameterFilter { $Path -match 'Propo|README' }
        Should -Invoke Send-DFFontChange -Times 1 -Exactly
        $result.Face | Should -Be 'Hack Nerd Font'
        @($result.Files).Count | Should -Be 3
    }

    It 'says which face to select in the terminal' {
        Install-DFNerdFont -Name Hack | Out-Null
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Installed Hack Nerd Font. Select "Hack Nerd Font" as your terminal''s font, then open a new shell to see icons.' }
    }

    It 'asks which font when no name is given' {
        Install-DFNerdFont | Out-Null
        Should -Invoke Select-DFNerdFontName -Times 1 -Exactly
    }

    It 'reports files already installed as skipped and broadcasts nothing when none was new' {
        Mock Install-DFFontFile { $false }
        $result = Install-DFNerdFont -Name Hack
        @($result.Skipped).Count | Should -Be 3
        @($result.Files).Count | Should -Be 0
        Should -Invoke Send-DFFontChange -Times 0
    }

    It 'says the font was already installed when every file was' {
        Mock Install-DFFontFile { $false }
        Install-DFNerdFont -Name Hack | Out-Null
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match '^Hack Nerd Font is already installed\.' }
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -match '^Installed' }
    }

    It 'fails, claiming nothing, when the download holds no Nerd Font files' {
        $empty = Join-Path $TestDrive "empty-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory $empty -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $empty 'README.md') 'x'
        [IO.Compression.ZipFile]::CreateFromDirectory($empty, "$empty.zip")
        $script:Zip = "$empty.zip"
        Install-DFNerdFont -Name Hack -ErrorVariable err -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        "$err" | Should -Match 'no Nerd Font files'
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -match '^Installed' }
    }

    It 'changes nothing with -WhatIf' {
        Install-DFNerdFont -Name Hack -WhatIf | Out-Null
        Should -Invoke Save-DFNerdFontArchive -Times 0
        Should -Invoke Install-DFFontFile -Times 0
    }

    It 'rejects a font outside its list' {
        { Install-DFNerdFont -Name Comic } | Should -Throw
    }
}

Describe 'Install-DFFontFile' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:Folder = Join-Path $TestDrive "fonts-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $script:Key = "TestRegistry:\Fonts-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -Path $script:Key -Force | Out-Null
        $script:Font = Join-Path $TestDrive 'HackNerdFont-Regular.ttf'
        Set-Content -LiteralPath $script:Font 'font' -NoNewline
        Mock Add-DFFontResource { }
    }

    It 'copies the font, registers its full path for the user and loads it' {
        Install-DFFontFile -Path $script:Font -FontFolder $script:Folder -RegistryKey $script:Key | Should -BeTrue
        $target = Join-Path $script:Folder 'HackNerdFont-Regular.ttf'
        Test-Path -LiteralPath $target | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:Key).'HackNerdFont-Regular (TrueType)' | Should -Be $target
        Should -Invoke Add-DFFontResource -Times 1 -Exactly -ParameterFilter { $Path -eq $target }
    }

    It 'lets packaged apps such as Windows Terminal read it' {
        Install-DFFontFile -Path $script:Font -FontFolder $script:Folder -RegistryKey $script:Key | Out-Null
        $acl = Get-Acl -LiteralPath (Join-Path $script:Folder 'HackNerdFont-Regular.ttf')
        $sids = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]).IdentityReference.Value
        $sids | Should -Contain 'S-1-15-2-1'
        $sids | Should -Contain 'S-1-15-2-2'
    }

    It 'skips a font already installed and registered' {
        Install-DFFontFile -Path $script:Font -FontFolder $script:Folder -RegistryKey $script:Key | Out-Null
        Install-DFFontFile -Path $script:Font -FontFolder $script:Folder -RegistryKey $script:Key | Should -BeFalse
        @((Get-Item -LiteralPath $script:Key).GetValueNames()).Count | Should -Be 1
        Should -Invoke Add-DFFontResource -Times 1 -Exactly
    }

    It 'repairs a font whose file is there but whose registration is not' {
        New-Item -ItemType Directory $script:Folder -Force | Out-Null
        Copy-Item -LiteralPath $script:Font -Destination $script:Folder
        Install-DFFontFile -Path $script:Font -FontFolder $script:Folder -RegistryKey $script:Key | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:Key).'HackNerdFont-Regular (TrueType)' | Should -Not -BeNullOrEmpty
    }
}

Describe 'Select-DFNerdFontName' -Skip:(-not $IsWindows) {
    BeforeEach { Mock Write-Host { } }

    It 'installs CaskaydiaMono and says so when it can''t ask' {
        Mock Test-DFFzfAvailable { $false }
        Mock Test-DFInteractiveHost { $false }
        Select-DFNerdFontName | Should -Be 'CaskaydiaMono'
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'CaskaydiaMono' }
    }

    It 'offers a numbered list without fzf, Enter taking the first' {
        Mock Test-DFFzfAvailable { $false }
        Mock Test-DFInteractiveHost { $true }
        Mock Read-Host { '' }
        Select-DFNerdFontName | Should -Be 'CaskaydiaMono'
        Mock Read-Host { '5' }
        Select-DFNerdFontName | Should -Be 'Hack'
    }

    It 'never opens fzf when no one can answer it' {
        Mock Test-DFFzfAvailable { $true }
        Mock Test-DFInteractiveHost { $false }
        Mock Invoke-DFPicker { 'Hack' }
        Select-DFNerdFontName | Should -Be 'CaskaydiaMono'
        Should -Invoke Invoke-DFPicker -Times 0
    }

    It 'lists the fonts in the picker, CaskaydiaMono first' {
        Mock Test-DFFzfAvailable { $true }
        Mock Test-DFInteractiveHost { $true }
        Mock Invoke-DFPicker { $script:Listed = @(& $List); 'FiraCode' }
        Select-DFNerdFontName | Should -Be 'FiraCode'
        $script:Listed | Should -Be @('CaskaydiaMono', 'JetBrainsMono', 'FiraCode', 'Meslo', 'Hack')
    }
}

Describe 'Install-DFNerdFont off Windows' -Skip:($IsWindows) {
    It 'installs nothing and points at the installer tools' {
        Mock Save-DFNerdFontArchive { }
        Install-DFNerdFont -Name Hack -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
        "$err" | Should -Match 'Windows'
        Should -Invoke Save-DFNerdFontArchive -Times 0
    }
}
