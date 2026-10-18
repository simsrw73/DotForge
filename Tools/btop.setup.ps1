# One-time setup for btop: copy the catppuccin themes (catppuccin/btop, MIT) into
# btop's own themes folder, beside btop.exe, without replacing any there. Choosing one
# stays yours: btop.conf (color_theme) is your file, so a note names the theme that
# matches Theme. A btop that can't be found is skipped with a note.
$_exe = (Get-Command -Name 'btop' -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
$_target = if ($_exe) { Resolve-DFExecutableTarget -Path $_exe }
$_copied = @()
if ($_target -and (Test-Path -LiteralPath $_target -PathType Leaf)) {
    $_themes = Join-Path (Split-Path $_target) 'themes'
    New-DFDirectory $_themes | Out-Null
    foreach ($_file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'btop') -Filter 'catppuccin_*.theme') {
        $_dest = Join-Path $_themes $_file.Name
        if (-not (Test-Path -LiteralPath $_dest)) { Copy-Item -LiteralPath $_file.FullName -Destination $_dest; $_copied += $_dest }
    }
    $_flavor = (Get-DFToolTheme -Tool $DFCurrentTool).Value
    Add-DFToolSetupNote -Name 'btop' -Text "catppuccin themes are in btop's themes folder; to use one, set color_theme = `"$_flavor`" in $(Join-Path (Split-Path $_target) 'btop.conf'), or pick it in btop's options (Esc)."
} else {
    Add-DFToolSetupNote -Name 'btop' -Text "couldn't find btop.exe to copy its catppuccin themes; run Invoke-DFToolSetup btop once btop is on PATH."
}
Complete-DFToolSetup -Name 'btop' -Actions @(foreach ($_path in $_copied) { @{ type = 'seedConfig'; path = $_path; created = $true } })