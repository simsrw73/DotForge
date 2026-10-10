#Requires -Version 7.2

function Invoke-DFWithPager {
    <#
    .SYNOPSIS
        Pipes output through the pager named by $Env:Pager, or prints it when none is set.
    .DESCRIPTION
        Accepts either pipeline input or a scriptblock. Collects all output as
        strings, then either sends it to the external pager named by $Env:Pager
        (via Invoke-DFPagerExe) or writes it to the success stream when no pager
        is configured. Nothing is sent to the pager when the collected result is
        empty.

        $Env:Pager is a command line split on whitespace: the first word is the
        executable, the rest are its arguments (e.g. 'less -R' or
        'bat --paging=always'). Quoted arguments are not supported; use the
        --key=value form instead. A warning is written when quotes are present.

        Side effects: starts the pager process. Reads $Env:Pager only.
    .PARAMETER InputObject
        String values piped in from the pipeline. Non-string objects are
        converted with their default ToString(). Ignored, with a warning, when
        -Command is also given.
    .PARAMETER Command
        Optional scriptblock whose output is used instead of pipeline input. Each
        output object is converted to a string.
    .EXAMPLE
        Get-ChildItem | Select-Object -ExpandProperty Name | Invoke-DFWithPager

        Pages the names of the files in the current directory.
    .EXAMPLE
        $Env:Pager = 'less -R'
        pg { git log --oneline }

        Runs the scriptblock and pages its output through less, using the pg alias.
    .OUTPUTS
        System.String. Emitted only when $Env:Pager is unset; otherwise the
        output goes to the pager and nothing is returned.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/pickers-and-helpers.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [string]$InputObject,

        [Parameter(Position = 0)]
        [scriptblock]$Command
    )
    begin   { $lines = [System.Collections.Generic.List[string]]@() }
    process { if ($null -ne $InputObject) { $lines.Add($InputObject) } }
    end {
        if ($Command) {
            if ($lines.Count -gt 0) {
                Write-Warning 'Invoke-DFWithPager: both pipeline input and -Command were provided; pipeline input is ignored.'
            }
            $lines = @(& $Command | ForEach-Object { "$_" })
        }
        if ($Env:Pager -and $lines.Count -gt 0) {
            Invoke-DFPagerExe -Lines $lines -Pager $Env:Pager
        } else {
            $lines
        }
    }
}
Set-Alias -Name pg -Value Invoke-DFWithPager
