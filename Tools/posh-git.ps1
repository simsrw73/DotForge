# Companion for posh-git — imports the module and defines the git fzf pickers
# fco, flog, fga and fstash (global functions plus aliases).
# Dot-sourced by Register-DFTool when the posh-git module is available.
# Reads: nothing from $DFConfig. Writes: no files. Every picker shells out to git
# in the current directory and needs fzf (or $Env:Picker).
Import-Module posh-git -ErrorAction SilentlyContinue

function global:Select-GitBranch {
    <#
    .SYNOPSIS
        Fuzzy-picks a git branch, local or remote, and checks it out.
    .DESCRIPTION
        Lists every branch from git branch --all in fzf, with the branch's recent
        commits (git log --oneline) in the preview pane. Enter runs git checkout
        on the selection. A remote branch is checked out by its short name
        (remotes/origin/feature becomes feature), which lets git create a local
        tracking branch. Esc does nothing.

        Run it inside a git work tree. Defined by DotForge's posh-git companion;
        requires fzf (or $Env:Picker).
    .EXAMPLE
        fco

        Opens the branch picker; Enter switches to the highlighted branch.
    .OUTPUTS
        None. git checkout writes its own messages.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git branch --all --color=always } `
        -Preview       'git log --oneline --color=always {1}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select branch  [Enter to checkout]' `
        -Parse         { $_ -replace '^\*\s+', '' -replace '^\s+remotes/[^/]+/', '' -replace '^\s+', '' } `
        -Action        { param($b) git checkout $b }
}
Set-Alias -Name fco -Value Select-GitBranch -Scope Global -Force

function global:Select-GitLog {
    <#
    .SYNOPSIS
        Fuzzy-browses the commit log and shows the selected commit.
    .DESCRIPTION
        Lists git log --oneline for the current branch in fzf, previewing each
        commit's full diff (git show). Enter prints the selected commit with
        git show. Esc does nothing. Read-only.

        Run it inside a git work tree. Defined by DotForge's posh-git companion;
        requires fzf (or $Env:Picker).
    .EXAMPLE
        flog

        Opens the log picker; Enter shows the highlighted commit.
    .OUTPUTS
        System.String. The git show output for the selected commit.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
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
    <#
    .SYNOPSIS
        Fuzzy-picks changed files and stages them with git add.
    .DESCRIPTION
        Lists git status --short in fzf, previewing each file's unstaged diff.
        Mark several files with Tab, then press Enter to git add each one; the
        new git status --short is printed afterwards. For a rename, the new path
        is staged. Esc stages nothing.

        Run it inside a git work tree. Defined by DotForge's posh-git companion;
        requires fzf (or $Env:Picker).
    .EXAMPLE
        fga

        Opens the changed-files picker; Tab marks files, Enter stages them.
    .OUTPUTS
        System.String. The git status --short lines after staging.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
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
            # 'XY PATH': two status columns, a space, then the path. X is blank for
            # an unstaged change, so splitting on whitespace would misread ' M path'.
            # A rename is 'R  old -> new'; stage the new path.
            $file = $_.Substring(3)
            if ($file -like '* -> *') { $file = ($file -split ' -> ', 2)[1] }
            git add $file
        }
        git status --short
    }
}
Set-Alias -Name fga -Value Select-GitFile -Scope Global -Force

function global:Select-GitStash {
    <#
    .SYNOPSIS
        Fuzzy-picks a stash entry and applies it.
    .DESCRIPTION
        Lists git stash list in fzf, previewing each entry's patch. Enter runs
        git stash apply on the selection, so the entry stays in the stash list
        (it is applied, not popped). Esc does nothing.

        Run it inside a git work tree. Defined by DotForge's posh-git companion;
        requires fzf (or $Env:Picker).
    .EXAMPLE
        fstash

        Opens the stash picker; Enter applies the highlighted stash.
    .OUTPUTS
        None. git stash apply writes its own messages.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List          { git stash list } `
        -Preview       'git stash show -p {}' `
        -PreviewWindow 'right:60%' `
        -Ansi `
        -Header        'Select stash  [Enter to apply]' `
        -Parse         { ($_ -split ':')[0] } `
        -Action        { param($ref) git stash apply $ref }
}
Set-Alias -Name fstash -Value Select-GitStash -Scope Global -Force
