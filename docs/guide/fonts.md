# Fonts and icons

**Audience:** anyone whose terminal shows `?` boxes or empty squares where icons should be, or who wants to install more fonts.  
**Topic:** Nerd Fonts, the icons DotForge turns on with them, and the font installers DotForge can set up.  
**Goal:** a Nerd Font installed and selected in your terminal, and icons that turn on by themselves.

## What a Nerd Font is

Several tools draw small icons: eza and lsd next to file names (`ls`, `ll`, `ff`), the `fzo` folder picker's preview, Terminal-Icons, and the prompt themes DotForge ships for oh-my-posh. Those icons are characters that only a *Nerd Font* has: an ordinary font with thousands of icon glyphs added. Without one, the terminal shows `?` boxes.

So each icon needs two things:

1. A Nerd Font **installed** on the machine.
2. That font **selected** in your terminal's settings.

DotForge can do the first and check it. It can't do the second, or see whether you did, because every terminal (Windows Terminal, WezTerm, …) keeps its font setting in its own place.

## When no Nerd Font is installed

On Windows, DotForge checks at each start whether a Nerd Font is installed. If none is, it turns off the icons it controls, so nothing shows `?` boxes, and says why at the end of the load:

```text
WARNING: DotForge: No Nerd Font installed, so icons are off. Run Install-DFNerdFont, or set NerdFont = $true if your terminal already has one.
```

With icons off:

- `ls`, `ll`, `la` and `ff` list without icons (eza and lsd);
- `fzo`'s preview lists without icons;
- Terminal-Icons isn't loaded (`Get-DFToolStatus Terminal-Icons` says why);
- oh-my-posh uses plain copies of DotForge's catppuccin themes, unless you have your own config;
- starship isn't changed: its symbols come from your own `starship.toml`.

Everything else works as usual.

## Install a Nerd Font

`Install-DFNerdFont` installs one for you alone, with no admin rights, registered so that it survives a reboot:

<!-- system -->

```powershell
Install-DFNerdFont -Name CaskaydiaMono
```

Without `-Name` it asks which one: CaskaydiaMono (the Nerd Font build of Cascadia, Windows Terminal's own font), JetBrainsMono, FiraCode, Meslo or Hack. When it's done, it names the font to select, for example `CaskaydiaMono Nerd Font`.

Then select that font in your terminal:

- **Windows Terminal:** Settings > Profiles > Defaults > Appearance > Font face.
- **WezTerm:** `config.font = wezterm.font 'CaskaydiaMono Nerd Font'` in `.wezterm.lua`.
- **Other terminals:** the font setting in their preferences.

Open a new shell. DotForge sees the font, turns icons on, and reminds you once to select it in the terminal.

## Turn icons on or off yourself

The `NerdFont` setting overrides the check:

<!-- fragment -->

```powershell
$DFConfig = @{
    Tools    = @('+core')
    NerdFont = $true    # icons on, whatever is installed
}
```

- `$true`: icons always on. Use it when your terminal brings its own icon font (WezTerm does), or when DotForge doesn't recognize your patched font's name.
- `$false`: icons always off, and no notice.
- Not set (the default): icons follow the check. Outside Windows there's no check, so icons are on.

## More font installers

For fonts beyond the first, `+fonts` sets up four installers. Each installs fonts for you alone, without admin rights:

<!-- system -->

```powershell
Install-DFTool -Name NerdFonts
```

| Tool | Installs | How to use it |
| --- | --- | --- |
| NerdFonts | Nerd Fonts | `Install-NerdFont -Name JetBrainsMono -Scope CurrentUser`; restart the terminal afterwards. |
| GoogleFonts | Google Fonts | `Install-GoogleFont -Name Inter -Scope CurrentUser`; restart the terminal afterwards. |
| fontget | Google Fonts, Nerd Fonts, Fontsource, Fontshare and more | `fontget add <font>`. Its per-user installs are lost on reboot until [FontGet#9](https://github.com/Graphixa/FontGet/issues/9) is fixed: use `--scope machine` (admin) meanwhile. |
| gfcli | Google Fonts | `gfcli install <font>`. Needs a JavaScript runtime (node or bun). |

scoop users can also install Nerd Fonts from the `nerd-fonts` bucket, which installs per user as well:

<!-- system -->

```powershell
scoop bucket add nerd-fonts
scoop install nerd-fonts/JetBrainsMono-NF
```

DotForge doesn't offer winget's or Chocolatey's Nerd Font packages: they install for every user and need admin rights.

## Troubleshooting

**The warning says no Nerd Font is installed, but I have one.** DotForge recognizes fonts named `… Nerd Font` or `… NF`/`NFM`/`NFP`, registered for you or for the machine. A font installed only for the current session (FontGet's per-user installs) isn't registered and is gone after a reboot. Reinstall it with `Install-DFNerdFont` or another installer above, or set `NerdFont = $true`.

**Icons are on, but I still see `?` boxes.** The font is installed but not selected in your terminal. Select it as shown in [Install a Nerd Font](#install-a-nerd-font).
