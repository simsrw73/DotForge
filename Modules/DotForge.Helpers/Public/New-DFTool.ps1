#Requires -Version 7.2

function New-DFTool {
    <#
    .SYNOPSIS
        Starts your own tool record in $XDG_CONFIG_HOME\dotforge\tools, or copies a shipped one there to change it.
    .DESCRIPTION
        DotForge loads the records in your tools folder
        ($XDG_CONFIG_HOME\dotforge\tools) along with the ones it ships, and a
        record there replaces the shipped record of the same name.

        With -Name, writes a starter <name>.json: the executable found on PATH
        (or a PowerShell module, which makes it a module tool), its
        description, and empty tags, aliases and picker to fill in. With
        -Companion, also writes a <name>.ps1 companion whose picker and
        completer examples are commented out.

        With -From, copies a shipped tool's record, companion, setup and manage
        scripts and data folder, so you can change them. Your copy replaces
        DotForge's, so DotForge's later fixes to that tool don't reach you;
        delete the copy to go back.

        Existing files are kept unless you pass -Force. After writing, it
        prints how to load the tool. See the "Your own tools" guide.
    .PARAMETER Name
        The tool's name; also the file name (<name>.json).
    .PARAMETER Executable
        The program that must be on PATH, when its name differs from the tool's
        (e.g. -Name ripgrep -Executable rg).
    .PARAMETER Companion
        Also write a <name>.ps1 companion skeleton.
    .PARAMETER From
        A shipped tool to copy into your folder.
    .PARAMETER Force
        Replace files that already exist.
    .EXAMPLE
        New-DFTool -Name lazygit -Companion

        Writes lazygit.json and lazygit.ps1 to your tools folder, ready to edit.
    .EXAMPLE
        New-DFTool -From bat

        Copies DotForge's bat record and companion to your tools folder, where your edits replace them.
    .OUTPUTS
        System.IO.FileSystemInfo. The files and folders written.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/your-own-tools.md
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'New')]
    [OutputType([System.IO.FileSystemInfo])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'New')]
        [ValidatePattern('^[\w.-]+$')][string]$Name,
        [Parameter(ParameterSetName = 'New')][string]$Executable,
        [Parameter(ParameterSetName = 'New')][switch]$Companion,
        [Parameter(Mandatory, ParameterSetName = 'From')]
        [ValidatePattern('^[\w.-]+$')][string]$From,
        [switch]$Force
    )

    $folder = Get-DFUserToolsPath
    $plan = if ($PSCmdlet.ParameterSetName -eq 'From') { Get-DFToolCopyPlan -Name $From -Folder $folder }
            else { Get-DFNewToolPlan -Name $Name -Executable $Executable -Companion:$Companion -Folder $folder }
    if (-not $plan) { return }

    $existing = @($plan.Items | Where-Object { Test-Path -LiteralPath $_.Path })
    if ($existing -and -not $Force) {
        Write-Error "DotForge: $(($existing.Path | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') already exists in $folder; use -Force to replace it."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($folder, $plan.Action)) { return }

    New-DFDirectory $folder | Out-Null
    foreach ($item in $plan.Items) {
        if ($item.Source) {
            # Copying a folder onto an existing one would nest it; replace it instead.
            if ((Test-Path -LiteralPath $item.Path -PathType Container)) { Remove-Item -LiteralPath $item.Path -Recurse -Force }
            Copy-Item -LiteralPath $item.Source -Destination $item.Path -Recurse -Force
        }
        else { [IO.File]::WriteAllText($item.Path, $item.Text) }
        Get-Item -LiteralPath $item.Path
    }
    if ($plan.Warning) { Write-Warning $plan.Warning }
    Write-Host "Edit $(Join-Path $folder "$($plan.Name).json"), then load it with: Register-DFTool -Name $($plan.Name)"
    Write-Host "To load it in every shell, add '$($plan.Name)' to Tools in your Start-DFSession config."
}
