function Register-DFLazyCompleter {
    <#
    .SYNOPSIS
        Registers a command's completer so that it loads on the first Tab, not at startup.
    .DESCRIPTION
        For a tool whose own completer is slow to load (uv's is a 757 KB script).
        Registers a small native completer for -CommandName. On the first Tab after
        that command it runs -Load once, which must register the real completer
        (Register-ArgumentCompleter, Import-Module, Invoke-Expression of the tool's
        script), then answers that same Tab through TabExpansion2, which now reaches
        the real completer. Later Tabs go straight to the real completer.

        If -Load fails, or registers nothing, the Tab gets no completions (PowerShell
        falls back to file names) and -Load is not run again.
    .PARAMETER CommandName
        The command to complete, e.g. 'uv'.
    .PARAMETER Load
        Registers the real completer. Runs at most once, at the first Tab. A sidecar
        that calls a private helper from it captures it first
        (`$cache = ${function:Get-DFCachedCommandOutput}`) and passes a closure.
    .EXAMPLE
        Register-DFLazyCompleter -CommandName uv -Load { Invoke-Expression (uv generate-shell-completion powershell | Out-String) }

        uv's completer loads the first time Tab is pressed after `uv`.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][scriptblock]$Load
    )

    $state = @{ Loaded = $false }
    $stub = {
        param($wordToComplete, $commandAst, $cursorPosition)
        # A second visit means -Load registered no replacement: answer nothing, never loop.
        if ($state.Loaded) { return }
        $state.Loaded = $true
        try { & $Load } catch {
            Write-Debug "DotForge: loading the $CommandName completer failed: $_"
            return
        }
        # The command's extent stops at its last word; a cursor past it (after a
        # trailing space) means "the next argument", so pad the text out to it.
        $text = $commandAst.Extent.Text
        $column = [Math]::Max($cursorPosition - $commandAst.Extent.StartOffset, 0)
        if ($column -gt $text.Length) { $text = $text.PadRight($column) }
        (TabExpansion2 -inputScript $text -cursorColumn $column).CompletionMatches
    }.GetNewClosure()
    Register-ArgumentCompleter -Native -CommandName $CommandName -ScriptBlock $stub
}
