#Requires -Version 7.0

function Get-DFPath {
    <#
    .SYNOPSIS
        Lists each directory in the PATH environment variable as a separate string.
    .DESCRIPTION
        Splits $Env:PATH on the platform path separator and emits one entry per
        line, in PATH order, making it easy to pipe into Where-Object,
        Select-String, or fzf for inspection and debugging. Entries are returned
        as stored: not normalized or deduplicated, and empty entries are kept.
    .EXAMPLE
        Get-DFPath

        Lists all directories in PATH, one per line.
    .EXAMPLE
        path | Where-Object { $_ -like '*python*' }

        Filters PATH entries that contain 'python' using the path alias.
    .OUTPUTS
        System.String — each PATH directory as a separate string.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param()
    $Env:PATH -split [IO.Path]::PathSeparator
}
function Select-DFEnvVar {
    <#
    .SYNOPSIS
        Fuzzy-searches environment variables and returns the value of the selected one.
    .DESCRIPTION
        Displays all environment variables in fzf, sorted by name, and returns
        the selected variable's value so it can be captured or piped to further
        commands. Both the name and the value are searchable. Returns nothing
        when you press Esc. Requires fzf (or $Env:Picker).
    .EXAMPLE
        Select-DFEnvVar

        Opens fzf to search env vars; outputs the value of the selected variable.
    .EXAMPLE
        $val = fenv

        Captures the selected environment variable's value into $val.
    .OUTPUTS
        System.String — the value of the selected environment variable.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param()
    Invoke-DFPicker `
        -List      { Get-ChildItem Env: | Sort-Object Name |
                     ForEach-Object { "$($_.Name)`t$($_.Value)" } } `
        -Delimiter "`t" `
        -Header    'Select env var  [Enter to output value]' `
        -Parse     { ($_ -split "`t", 2)[1] }
}
function Edit-DFProfile {
    <#
    .SYNOPSIS
        Opens the current PowerShell profile in the editor defined by $Env:EDITOR.
    .DESCRIPTION
        Launches $Env:EDITOR with $PROFILE as its only argument. $Env:EDITOR must
        be a single command name or path (e.g. 'code', 'nvim', or
        'C:\Program Files\Notepad++\notepad++.exe'); extra arguments such as
        'code -w' are not supported. Warns if $Env:EDITOR is not set rather than
        falling back to an unexpected editor. After saving, run
        Invoke-DFProfileReload (reload) to apply the changes.
    .EXAMPLE
        Edit-DFProfile

        Opens the current profile in whatever editor $Env:EDITOR points to.
    .EXAMPLE
        ep

        Same as above using the ep alias.
    .OUTPUTS
        None
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param()
    if (-not $Env:EDITOR) {
        Write-Warning 'DotForge: $Env:EDITOR is not set'
        return
    }
    & $Env:EDITOR $PROFILE
}
function Get-DFEnv {
    <#
    .SYNOPSIS
        Lists environment variables in KEY=VALUE format.
    .PARAMETER Pattern
        Wildcard filter on variable name. Defaults to * (all).
    .DESCRIPTION
        Emits all (or filtered) environment variables as KEY=VALUE strings sorted
        by name, mirroring the Unix env command output format for easy grepping
        and human scanning. When output is bound for an interactive terminal that
        supports VT sequences (and NO_COLOR is not set), it is colorized: the
        variable name in bold cyan, the '=' divider in bold yellow, and the value
        in faint so it recedes behind the name while adapting to any theme (faint
        dims the terminal's own foreground rather than forcing a fixed color).

        Color is suppressed automatically when the output is piped or redirected
        (e.g. `env | Where-Object`, `env > out.txt`) so downstream string matching
        and captured files never see ANSI escape sequences. NO_COLOR or a non-VT
        host likewise yields plain KEY=VALUE strings.
    .EXAMPLE
        Get-DFEnv

        Lists all environment variables in KEY=VALUE format, sorted by name.
    .EXAMPLE
        Get-DFEnv XDG*

        Lists only the XDG-prefixed environment variables.
    .OUTPUTS
        System.String — one KEY=VALUE string per matching environment variable.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Pattern = '*'
    )

    $useColor = Test-DFColorOutput -Invocation $MyInvocation
    # Name stands out, '=' is unmistakable, the value recedes (faint adapts to the theme).
    $p = Get-DFAnsiPalette -Color $useColor
    $name, $eq, $value, $reset = $p.Title, $p.Accent, $p.Faint, $p.Reset

    Get-ChildItem Env: |
        Where-Object Name -like $Pattern |
        Sort-Object Name |
        ForEach-Object {
            if ($useColor) {
                "$name$($_.Name)$reset$eq=$reset$value$($_.Value)$reset"
            } else {
                "$($_.Name)=$($_.Value)"
            }
        }
}
function Invoke-DFProfileReload {
    <#
    .SYNOPSIS
        Re-dot-sources the current PowerShell profile to apply changes without restarting.
    .DESCRIPTION
        Dot-sources $PROFILE into the caller's scope, so edits to functions,
        aliases, variables, env vars and module imports take effect without
        starting a new shell. Run it from the prompt.

        Reloading does not undo anything: a function or alias you deleted from
        the profile stays defined until the session ends. Import-Module without
        -Force does not re-import an already-loaded module, so changes to a
        module's own code still need Import-Module -Force or a new session.

        Warns if $PROFILE does not exist rather than silently succeeding.
    .EXAMPLE
        Invoke-DFProfileReload

        Re-applies all profile settings in the current session.
    .EXAMPLE
        reload

        Same as above using the reload alias — useful after editing the profile with ep.
    .OUTPUTS
        Whatever the profile itself writes to the output stream; usually none.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param()
    if (Test-Path $PROFILE) {
        # A plain `. $PROFILE` here would dot-source into this module function's own
        # scope, so the profile's functions, aliases and variables would vanish on
        # return. Run it in the caller's session state instead. The scriptblock is
        # built from a string so it is not bound to the module's session state.
        $dotSource = [scriptblock]::Create(". '$($PROFILE -replace "'", "''")'")
        $PSCmdlet.SessionState.InvokeCommand.InvokeScript($PSCmdlet.SessionState, $dotSource, @())
    } else {
        Write-Warning "DotForge: `$PROFILE not found at $PROFILE"
    }
}
