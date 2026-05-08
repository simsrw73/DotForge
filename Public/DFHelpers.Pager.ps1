#Requires -Version 7.0

function Invoke-DFWithPager {
    <#
    .SYNOPSIS
        Layer 1 primitive — pipes output through $Env:Pager when set.
    .DESCRIPTION
        Accepts either pipeline input or a scriptblock. Collects all output, then
        either sends it to the external pager named by $Env:Pager (via
        Invoke-DFPagerExe) or writes directly to stdout when no pager is configured.
        No output is sent to the pager when the collected result is empty.
    .PARAMETER InputObject
        String values piped in from the pipeline.
    .PARAMETER Command
        Optional scriptblock whose output is used instead of pipeline input.
    .EXAMPLE
        Get-ChildItem | Select-Object -ExpandProperty Name | Invoke-DFWithPager
    .EXAMPLE
        Invoke-DFWithPager { git log --oneline }
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
            $lines = & $Command | ForEach-Object { "$_" }
        }
        if ($Env:Pager -and $lines.Count -gt 0) {
            Invoke-DFPagerExe -Lines $lines -Pager $Env:Pager
        } else {
            $lines
        }
    }
}
Set-Alias -Name pg -Value Invoke-DFWithPager -Scope Global -Force
