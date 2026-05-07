# Companion for posh-git — git fzf pickers (fco, flog, fga, fstash)
# Dot-sourced by Register-DFTool when posh-git module is available.

function global:Select-GitBranch {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git branch --all --color=always } `
        -Preview       'git log --oneline --color=always {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select branch  [Enter to checkout]' `
        -Parse         { $_ -replace '^\*\s+', '' -replace '^\s+remotes/origin/', '' -replace '^\s+', '' } `
        -Action        { param($b) git checkout $b }
}
Set-Alias -Name fco -Value Select-GitBranch -Scope Global -Force

function global:Select-GitLog {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git log --oneline --color=always } `
        -Preview       'git show --color=always {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select commit  [Enter to show]' `
        -Parse         { ($_ -split ' ')[0] } `
        -Action        { param($sha) git show $sha }
}
Set-Alias -Name flog -Value Select-GitLog -Scope Global -Force

function global:Select-GitFile {
    [CmdletBinding()]
    param()
    $files = Invoke-DFPicker `
        -List          { git status --short } `
        -Preview       'git diff --color=always {2}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Multi `
        -Header        'Select files to stage  [Tab=multi, Enter to git add]'
    if ($files) {
        @($files) | ForEach-Object {
            $file = ($_ -split '\s+', 2)[1].Trim()
            git add $file
        }
        git status --short
    }
}
Set-Alias -Name fga -Value Select-GitFile -Scope Global -Force

function global:Select-GitStash {
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git stash list } `
        -Preview       'git stash show -p {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select stash  [Enter to apply]' `
        -Parse         { ($_ -split ':')[0] } `
        -Action        { param($ref) git stash apply $ref }
}
Set-Alias -Name fstash -Value Select-GitStash -Scope Global -Force
