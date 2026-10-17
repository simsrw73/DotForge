# One-time setup for starship: Theme changes starship's colors by swapping the
# top-level palette line of your starship.toml (in a copy; your file is never
# written). A config without one can't follow Theme, so say so once.
$_source = if ($Env:STARSHIP_CONFIG) { $Env:STARSHIP_CONFIG } else { ConvertTo-DFPath (Expand-DFXdgPath '${XDG_CONFIG_HOME}/starship/starship.toml') }
if ((Test-Path -LiteralPath $_source -PathType Leaf) -and -not (Select-String -LiteralPath $_source -Pattern '^\s*palette\s*=' -Quiet)) {
    Add-DFToolSetupNote -Name 'starship' -Text 'your starship.toml sets no palette, so Theme can''t change its colors; add palette = "catppuccin_mocha" (and its [palettes.catppuccin_mocha] table) to use it.'
}
Complete-DFToolSetup -Name 'starship'