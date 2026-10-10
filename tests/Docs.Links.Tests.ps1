#Requires -Version 7.2
# Every relative link and image in the user docs must point at a file that
# exists, and every #anchor at a heading that exists. External URLs are not
# fetched.

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'build' 'DFDocExamples.ps1')
    $docs = @(
        Join-Path $repo 'README.md'
        Join-Path $repo 'examples' 'README.md'
        Get-ChildItem (Join-Path $repo 'docs' 'guide') -Filter '*.md' -ErrorAction Ignore | ForEach-Object FullName
        Join-Path $repo 'docs' 'reference.md'
    ) | Where-Object { Test-Path $_ }
    $script:links = foreach ($d in $docs) {
        foreach ($l in Get-DFDocLink -Path $d) {
            @{ Rel = [IO.Path]::GetRelativePath($repo, $l.File) -replace '\\', '/'; Line = $l.Line; Target = $l.Target
               TargetPath = $l.TargetPath; Anchor = $l.Anchor; File = $l.File }
        }
    }
}

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'build' 'DFDocExamples.ps1')
}

Describe 'Documentation links' {
    It '<Rel>:<Line> -> <Target>' -ForEach $script:links {
        $targetFile = $TargetPath ?? $File
        Test-Path $targetFile | Should -BeTrue -Because "$Target does not exist"
        if ($Anchor -and $targetFile -like '*.md') {
            Get-DFDocHeadingSlug -Path $targetFile | Should -Contain $Anchor -Because "no heading in $targetFile has the anchor #$Anchor"
        }
    }
}
