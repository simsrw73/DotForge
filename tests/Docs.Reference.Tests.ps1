#Requires -Version 7.2
# docs/reference.md is generated from comment-based help. If this fails, a
# function's help changed without regenerating the page: run
#   ./build/Build-DFReferenceDocs.ps1
# and commit the result.

Describe 'docs/reference.md' {
    It 'matches what build/Build-DFReferenceDocs.ps1 generates' {
        $repo = Split-Path $PSScriptRoot -Parent
        $fresh = Join-Path $TestDrive 'reference.md'
        # A child process, so the generator's module import can't disturb this session.
        $output = @(pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'build' 'Build-DFReferenceDocs.ps1') -OutputPath $fresh 2>&1)
        $LASTEXITCODE | Should -Be 0
        $output | Should -Not -Match 'Cannot index into a null array'
        $committed = Join-Path $repo 'docs' 'reference.md'
        Test-Path $committed | Should -BeTrue -Because 'the generated reference must be committed'
        (Get-Content $fresh -Raw) | Should -BeExactly (Get-Content $committed -Raw) -Because 'docs/reference.md is stale; run ./build/Build-DFReferenceDocs.ps1'
    }
}
