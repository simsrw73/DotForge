# Fonts: a Nerd Font on first run, and font installers (T-73, T-71)

Status: draft, 2026-10-23.

## Goal

On a fresh Windows install, DotForge turned on tools that draw Nerd Font icons (starship, eza, the
pickers), but no Nerd Font was installed. The terminal showed `?` boxes and nothing said why. This
batch:

1. detects whether a Nerd Font is installed, and turns optional icons off when it isn't (T-71's
   `NerdFont` setting, folded in);
2. says so on every load while it holds, with the fix;
3. installs a Nerd Font with one command, in plain PowerShell, without admin rights;
4. onboards font installers as ordinary tools, for fonts beyond that first one.

## What the user said

- Two problems: what to do about fonts on a first install or restore, and giving users tools to
  install new fonts.
- Priority for the first: "that it gets a nerd font with little effort, as long as it makes clear to
  the user when it loads that the reason for no icons are the missing nerd fonts."
- Configuring the terminal for them "might be a lot", since it could be Windows Terminal, WezTerm, …
  (T-74 owns Windows Terminal.)
- FontGet "works great and has multiple sources, but it doesn't seem to register the fonts
  cleanly — after a reboot my terminal could no longer see the fonts even though they were there".
- For every installer: "whichever the user prefers, we need to mark and follow any dependencies."

## Decisions

1. **Get a Nerd Font with little effort**; a load without one says clearly that missing Nerd Fonts
   are why icons are off.
2. **A Nerd Font installed but not selected in the terminal:** trust the install. Icons turn on once
   any Nerd Font is installed; a one-time note says to select it in the terminal.
3. **Fonts are not tools.** DotForge onboards *installers* as ordinary tools; only the first-run
   Nerd Font install is built in. No `Fonts` config list.
4. **The built-in install is pure PowerShell**: no dependency, works on a bare machine.
5. **Font choice:** a picker over a short list; a parameter skips it.
6. **Installers onboarded:** the scoop nerd-fonts bucket, PSGallery `NerdFonts` and `GoogleFonts`,
   FontGet, gfcli. Each declares what it needs (`requires`) and installs through whichever source the
   user prefers, like any tool.
7. **A missed detection turns icons off.** The notice names both fixes: install a Nerd Font, or set
   `NerdFont = $true` when the terminal already has one. No migration for existing users.
8. **gfcli ships even if it loses fonts after a reboot**, with a warning note and an upstream issue,
   as FontGet does.

## Research

### Why FontGet's fonts vanish

Windows keeps per-user fonts in `%LOCALAPPDATA%\Microsoft\Windows\Fonts`. A font there survives a
sign-in only with a value under `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` (name
`<Face> (TrueType)`, value the file's **full path**; HKLM values are bare file names).
`AddFontResource` registrations last for the session only
([Font Installation and Deletion](https://learn.microsoft.com/en-us/windows/win32/gdi/font-installation-and-deletion)).
FontGet's `internal/platform/windows.go` copies the file and calls `AddFontResource`, but writes the
registry value only for machine scope, under HKLM. Filed upstream as
[Graphixa/FontGet#9](https://github.com/Graphixa/FontGet/issues/9).

### Installers

| Installer | Sources | Per-user, no admin | Persists (registry) | List / remove |
|---|---|---|---|---|
| `oh-my-posh font install` | Nerd Fonts | yes | yes (HKCU + `AddFontResourceW`) | no |
| scoop nerd-fonts bucket | Nerd Fonts | yes (`-g` = machine, admin) | yes (HKCU; also grants app-container SIDs read) | yes |
| PSGallery `NerdFonts` / `GoogleFonts` (on `Fonts`) | Nerd / Google Fonts | yes | yes; no `AddFontResource`, so running apps need a restart | yes |
| FontGet | Google, Nerd, Fontsource, Fontshare, … | yes | **no** per-user (FontGet#9); machine scope needs admin | yes |
| gfcli (npm `google-font-cli`) | Google Fonts | yes | unverified (hands off to a WScript helper) | no |
| winget `DEVCOM.*NerdFont`, choco | Nerd Fonts | no (machine, UAC) | HKLM | yes |

### Detection

Read the HKCU and HKLM Fonts keys and check that each matching file exists. Never
`[System.Drawing.Text.InstalledFontCollection]`: it lists what this session has loaded, so it would
have reported FontGet's fonts as installed until the reboot.

### Where icons come from today

| Source | Where | Off switch |
|---|---|---|
| eza, lsd | role words `icons` / `icons-always` (`data/roles.json:44-53`, `Tools/eza.json:20`, `Tools/lsd.json:35`) | omit the flag, or `--icons=never` / `--icon=never` |
| zoxide `fzo` | preview `eza --icons --color=always {}` (`Tools/zoxide.json:33`) | drop the flag |
| Terminal-Icons | the whole module (`Tools/Terminal-Icons.ps1`; prewarmed in `Private/Start-DFModulePrewarm.ps1:50-66`) | don't load it |
| oh-my-posh | glyphs in the bundled catppuccin themes (`Tools/oh-my-posh/*.omp.json`) | an icon-free theme |
| starship | the user's own `starship.toml` only; DotForge seeds none | the user's choice |
| broot | `icon_theme: nerdfont` commented out in the seeded `Tools/broot/conf.hjson` | already off |

## Design

### A. Detection (startup core)

- A Nerd Font is present when a value name under the HKCU or HKLM Fonts key matches a normalized
  pattern (`NerdFont`, `Nerd Font`, a trailing ` NF`, `NFM`, `NFP`) and its file exists.
- The result is kept in a state file under `Get-DFXdgPath State`, reused while the two keys are
  unchanged (value count and last-write time), so a normal start pays almost nothing. Measure
  startup before and after. *(My call.)*
- Not Windows: assume present; the setting below still forces icons off. *(My call.)*

### B. The icon gate (T-71)

- New config key `NerdFont` (in `$script:DFConfigKeys`): unset = detection decides, `$true` = icons
  on (a terminal that brings its own symbols, such as WezTerm), `$false` = icons off.
- Records declare which of their behavior is icons; core never names a tool:
  - **eza, lsd:** with icons off, the `icons`/`icons-always` role words produce no flag, or a
    declared off flag (`--icons=never`). One home for the rule; the builder picks the mechanism.
  - **zoxide `fzo`:** its preview's `--icons` goes through the same gate.
  - **Terminal-Icons:** not activated, and not prewarmed, when icons are off.
  - **oh-my-posh:** icon-free variants of the bundled themes, used when icons are off.
  - **starship:** left alone (the user's config). **broot:** stays off; turning `icon_theme` on
    with icons is the builder's call (the seed is copied once).
- A tool whose icons were turned off says so in `Get-DFToolStatus`.

### C. Messages at load

- Icons off by detection: one line at the end of the load, next to the missing-tools list, on every
  load while it holds: *"No Nerd Font installed, so icons are off. Run `Install-DFNerdFont`, or set
  `NerdFont = $true` if your terminal already has one."* Not shown when the user set
  `NerdFont = $false`.
- A one-time note (setup-note style) when a Nerd Font appears: it names the face and says to select
  it in the terminal. It fires only on an absent → present change recorded by the detection state,
  or after `Install-DFNerdFont`. The first detection ever, with a font already present, records a
  baseline and shows nothing, so existing users see no note. *(My call.)*

### D. `Install-DFNerdFont`

- Public, in an on-demand module (only an explicit command needs it). Check the name against
  `Get-Command` per `docs/builtin-safety-policy.md`. *(Name: my call.)*
- `-Name <font>` skips the picker. Otherwise a picker over CaskaydiaMono (preselected: the Nerd Font
  build of Windows Terminal's own Cascadia), JetBrainsMono, FiraCode, Meslo and Hack. *(List: my
  call.)* Without fzf, a numbered menu in an interactive host; a non-interactive host installs
  CaskaydiaMono and says so. *(My call.)*
- Downloads the font's zip from the latest `ryanoasis/nerd-fonts` release, extracts it to a temp
  folder, copies the `.ttf` files to `$Env:LOCALAPPDATA\Microsoft\Windows\Fonts`, writes one HKCU
  value per file, grants the app-container SIDs (`S-1-15-2-1`, `S-1-15-2-2`) read access so packaged
  apps such as Windows Terminal can read them, calls `AddFontResourceW` and broadcasts
  `WM_FONTCHANGE`. Skips files already installed. Supports `-WhatIf`.
- Prints the exact face name to select in the terminal and clears the cached detection.
- Never runs during a load. Windows only; elsewhere it says so and points at the installer tools.
- Download, registry and P/Invoke sit behind private functions tests can mock; no test installs a
  font.

### E. Installer tools

| Record | Installs through | `requires` | Notes |
|---|---|---|---|
| scoop nerd-fonts bucket | scoop feed `{ name: "nerd-fonts", url: "https://github.com/matthewjberger/scoop-nerd-fonts" }` | scoop | Fonts install as `scoop install nerd-fonts/<Font>-NF`. Tool record or a feed on scoop's record: builder's call. |
| NerdFonts | psgallery `NerdFonts` | psresource | Pulls in `Fonts`. Note: restart the terminal after installing a font. |
| GoogleFonts | psgallery `GoogleFonts` | psresource | Same engine. |
| FontGet | winget `Graphixa.FontGet`, scoop | (by source) | `setup.notes`: per-user installs don't survive a reboot until FontGet#9 is fixed; use `--scope machine` (admin) or another installer. Entry in `docs/external-dependencies.md`. |
| gfcli | npm `google-font-cli` | node/npm, as the npm source requires | Verify on a real install how it registers fonts; if it loses them on reboot, ship with a warning note and file an upstream issue. |

A category role `font-installer` (`data/roles.json`) and a `+fonts` group (`data/groups.json`).
*(My call.)*

## Out of scope

- Configuring any terminal (T-74 owns Windows Terminal).
- Fonts as tool records, or a `Fonts` config list.
- Non-Nerd fonts in the built-in install.

## Testing

- Detection: registry reads behind a mockable private function; cache reuse and invalidation; the
  name patterns, including misses.
- Gate: eza/lsd aliases without icons when off, `fzo` preview, Terminal-Icons neither activated nor
  prewarmed, oh-my-posh theme choice, status lines; each `NerdFont` value.
- Messages: the load line (shown, suppressed by `NerdFont = $false`), the one-time note on an
  absent → present change only.
- `Install-DFNerdFont`: `-WhatIf`, `-Name`, picker and numbered-menu paths, skip-if-installed, all
  side effects mocked.
- Installer records: the existing record, registry and docs tests.
- Manual, on a dev build (`./build/Publish-DFLocal.ps1 -Install`): on a machine without a Nerd Font,
  a new shell shows plain output and the notice; `Install-DFNerdFont` installs per-user; after a
  reboot the font is still there and icons render once the terminal uses it.
