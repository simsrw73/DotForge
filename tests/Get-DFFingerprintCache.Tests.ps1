BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}

Describe 'Get-DFFingerprintCache' {
    BeforeEach {
        Set-DFTestXdg
        $script:Dir = Join-Path $Env:XDG_CACHE_HOME 'dotforge'
        # $TestDrive lives for the whole Describe; start every test with no cache.
        Remove-Item $script:Dir -Recurse -Force -ErrorAction Ignore
        $script:Calls = 0
    }
    AfterEach { Restore-DFTestXdg }

    It 'generates on a cold cache and writes <name>.txt and <name>.key' {
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { $script:Calls++; 'value' } | Should -Be 'value'
        $script:Calls | Should -Be 1
        (Get-Content (Join-Path $script:Dir 't.txt') -Raw).Trim() | Should -Be 'value'
        (Get-Content (Join-Path $script:Dir 't.key') -Raw).Trim() | Should -Be 'fp1'
    }

    It 'serves the cache without generating when the fingerprint matches' {
        $null = Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'first' }
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { throw 'must not run' } | Should -Be 'first'
    }

    It 'regenerates when the fingerprint changes, and with -Force' {
        $null = Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'old' }
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp2' -Generate { 'new' } | Should -Be 'new'
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp2' -Generate { 'forced' } -Force | Should -Be 'forced'
    }

    It 'never caches an empty result, so the next call generates again' {
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { $null } | Should -BeNullOrEmpty
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { '   ' } | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:Dir 't.key') | Should -BeFalse
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'later' } | Should -Be 'later'
    }

    It 'joins a multi-line result and returns the same text cold and warm' {
        $cold = Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'a', 'b', 'c' }
        $warm = Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { throw 'must not run' }
        $cold | Should -Be "a`nb`nc"
        $warm | Should -Be $cold
    }

    It 'writes atomically, the content before the key that vouches for it' {
        $script:writes = [System.Collections.Generic.List[string]]::new()
        Mock Write-DFFileAtomic { $script:writes.Add((Split-Path $Path -Leaf)) }
        $null = Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'value' }
        $script:writes | Should -Be @('t.txt', 't.key')
    }

    It 'treats a key file that does not match exactly as stale' {
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        Set-Content (Join-Path $script:Dir 't.txt') 'stale'
        Set-Content (Join-Path $script:Dir 't.key') 'fp1-old'
        Get-DFFingerprintCache -Name 't' -Fingerprint 'fp1' -Generate { 'fresh' } | Should -Be 'fresh'
    }
}
