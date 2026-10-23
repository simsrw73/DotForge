#Requires -Version 7.2

function Install-DFNerdFont {
    <#
    .SYNOPSIS
        Installs a Nerd Font for the current user, so tools can draw their icons.
    .DESCRIPTION
        Downloads the font from the latest Nerd Fonts release and installs its Nerd
        Font and Mono builds for you alone, without admin rights, registered so they
        survive a reboot. Without -Name, it asks which one: in fzf when it is
        installed, else from a numbered list, else (no one to ask) it installs
        CaskaydiaMono and says so. Files already installed are skipped.

        DotForge can't change your terminal's font: select the face it names in your
        terminal's settings (Windows Terminal: Settings > Profiles > Defaults >
        Appearance > Font face), then open a new shell. The next DotForge load sees
        the font and turns icons on (unless NerdFont is $false).

        Windows only. Elsewhere, install a Nerd Font with your package manager or
        one of the font installer tools (+fonts).
    .PARAMETER Name
        The font: CaskaydiaMono, JetBrainsMono, FiraCode, Meslo or Hack.
    .EXAMPLE
        Install-DFNerdFont -Name JetBrainsMono

        Installs JetBrainsMono Nerd Font and says to select it in the terminal.
    .EXAMPLE
        Install-DFNerdFont

        Asks which font to install.
    .OUTPUTS
        PSCustomObject { Name; Face; Files; Skipped }: the font, the face to select,
        and the files installed or already there. Nothing with -WhatIf or when the
        picker is cancelled.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/fonts.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('CaskaydiaMono', 'JetBrainsMono', 'FiraCode', 'Meslo', 'Hack')]
        [string]$Name
    )
    if (-not $IsWindows) {
        Write-Error 'Install-DFNerdFont installs fonts on Windows only. Install a Nerd Font with your package manager, or a font installer tool (+fonts).'
        return
    }
    if (-not $Name) { $Name = Select-DFNerdFontName }
    if (-not $Name) { return }
    $face = $script:DFNerdFontChoices[$Name]
    if (-not $PSCmdlet.ShouldProcess("$face (for you, from the latest Nerd Fonts release)", 'Install Nerd Font')) { return }

    $work = Join-Path ([IO.Path]::GetTempPath()) "dotforge-font-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-DFDirectory $work
    try {
        $zip = Save-DFNerdFontArchive -Name $Name -Destination $work
        # .NET, not Expand-Archive: no module to load into the session.
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $work 'files'))
        # The Nerd Font and Mono builds; Propo's proportional spacing doesn't suit a terminal.
        $fontFiles = Get-ChildItem -LiteralPath (Join-Path $work 'files') -Recurse -File |
            Where-Object { $_.Extension -in '.ttf', '.otf' -and $_.BaseName -match 'NerdFont(Mono)?-' }
        if (-not $fontFiles) {
            Write-Error "The $Name download holds no Nerd Font files (*NerdFont-*, *NerdFontMono-*); nothing was installed. The release may have renamed them."
            return
        }
        $installed = [System.Collections.Generic.List[string]]::new()
        $skipped = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $fontFiles) {
            if (Install-DFFontFile -Path $file.FullName) { $installed.Add($file.Name) } else { $skipped.Add($file.Name) }
        }
        if ($installed.Count) { Send-DFFontChange }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Ignore
    }
    $done = if ($installed.Count) { "Installed $face." } else { "$face is already installed." }
    Write-Host "$done Select `"$face`" as your terminal's font, then open a new shell to see icons."
    [pscustomobject]@{ Name = $Name; Face = $face; Files = [string[]]$installed.ToArray(); Skipped = [string[]]$skipped.ToArray() }
}
