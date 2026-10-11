# Startup banner — Design

**Date:** 2026-10-11
**Status:** Approved design; ready for implementation planning.

## Purpose

A system summary when a shell starts, like a Linux boot screen: one line the moment DotForge starts, then
fastfetch's system information with a line per physical drive (health from smartctl) and the public IP,
printed a line at a time. It must not make startup noticeably slower, and it must never wait on the
network.

Opt-in: `Start-DFSession -Config @{ ShowBanner = $true; ... }`.

## What the user sees

```
DotForge 0.7.0 · loading 31 tools…
OS  Windows 11 Pro (26H2) x86_64
...
Local IP (Ethernet)  192.168.99.20/24 (Ethernet)
Public IP  99.45.33.172
Disk (C:\)  C:\ (NTFS): 824.22 GiB / 930.62 GiB (89%)
...
Disk 990 PRO 2TB   NVMe · 99% life · 46°C · 14,014 h · 28 TB written
Disk 980 PRO 1TB   NVMe · 74% life · 48°C · 20,270 h · 147 TB written
Disk 860 EVO 1TB   SSD · 97% life · 38°C · 70,634 h
Disk WD10EZEX      HDD · no bad sectors · 29°C · 84,115 h
```

1. The screen is cleared (unless `BannerClear = $false`), then the first line prints as soon as
   `Start-DFSession` starts, so the user knows something is happening.
2. The rest prints when `Start-DFSession` finishes (after the tools load), one line every `BannerLineDelay`
   milliseconds (default 8, `0` prints at once), like a printer.
3. With fastfetch but no smartmontools there are no drive lines; with neither, only the first line.
4. Shown only in an interactive console host: not with `-NonInteractive`, not when output is redirected.

## Colors and style

DotForge's own lines (the first line and every filled placeholder) look like fastfetch's: the key and
output colors and the separator come from the fastfetch config in use (`display.color.keys`,
`display.color.output`, `display.separator`), so they follow the user's config and the catppuccin theme
DotForge seeds. With no fastfetch config, the seeded default's colors are used. A failing drive line uses
catppuccin red `#f38ba8`.

## Drive lines (smartctl, no admin rights)

Measured on Windows 11 unelevated with smartctl 7.5: `smartctl --scan` ~110 ms; `smartctl -j -a -d <type>
<dev>` 120–250 ms per drive. All drives run in parallel.

| Drive kind | Life | Also shown |
| --- | --- | --- |
| NVMe | `100 - percentage_used` % life | temperature, power-on hours, TB written |
| SATA SSD | attribute 177 (Wear_Leveling_Count) or 231/233 normalized value, % life | temperature, power-on hours |
| HDD | none; "no bad sectors", or the counts of attributes 5, 197, 198 when non-zero | temperature, power-on hours |

- Label: the model name, shortened (vendor words like "Samsung SSD" dropped).
- A line is shown in red with the reason when the self-assessment fails, NVMe media errors > 0, any of
  attributes 5/187/197/198 is non-zero, or life is under 10%.
- A drive smartctl can't read is left out; when no drive can be read, no drive lines.

## Public IP

`Invoke-RestMethod https://api.ipify.org -TimeoutSec 2` in the background. Measured 60–140 ms.

## Timing

Everything slow runs in the background from the start, alongside tool activation:

1. `Start-DFSession` prints the first line, then starts each banner part's background work (thread jobs):
   fastfetch with its output captured (colors kept, `--pipe false`), the public IP lookup, `smartctl --scan`
   then each drive.
2. Tools activate as today.
3. At the end, results are collected. A part not finished waits at most `BannerWait` (default 300 ms)
   more; then its last cached value is used, marked `(cached)`, or its lines are left out if there is none.
4. Results are cached in `$XDG_CACHE_HOME\dotforge\banner.json` for the next shell.

fastfetch itself takes ~0.27 s, the same as today with the extra lines (measured), and now overlaps tool
activation instead of running before it.

## Placement: placeholders in the fastfetch config

fastfetch's `custom` module prints fixed text and spawns nothing (measured: no added time). The fastfetch
config holds placeholders where the extra lines go:

```jsonc
{ "type": "localip", "format": "{ipv4} ({ifname})" },
{ "type": "custom", "key": "Public IP", "format": "@DF:publicip@" },
{ "type": "disk", "format": "..." },
{ "type": "custom", "key": "Disk", "format": "@DF:drives@" }
```

DotForge replaces a placeholder line with its value; a multi-line value (one per drive) replaces the line
with several lines, each keyed and colored like fastfetch's own. A placeholder with no value removes its
line. Users move or delete placeholders to rearrange.

The `fastfetch` wrapper does the same substitution from the cache when run by hand, so `@DF:…` text never
shows.

## Plugin architecture

Core never names fastfetch or smartctl. A tool record declares a banner part:

```json
"banner": { "script": "fastfetch.banner.ps1", "body": true, "fills": ["publicip"] }
"banner": { "script": "smartmontools.banner.ps1", "fills": ["drives"] }
```

- `Tools/<tool>.banner.ps1` defines `Start-DFBannerPart` (starts the background work; returns a handle) and
  `Complete-DFBannerPart -Handle -WaitMs` (returns the body lines, and/or a map placeholder → lines).
- Core (`Private/DFBanner.ps1`): reads the setting, prints the first line, finds requested, installed tools
  with a `banner` field, loads each script in its own scope, starts the parts, and at the end collects
  them, fills placeholders in the body, caches, and prints. With no body part, only the first line shows.
- Schema: `banner.script` (file next to the record), `banner.body` (bool), `banner.fills` (placeholder
  names). A test enforces that every `fills` name is filled by exactly one part.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `ShowBanner` | `$false` | Show the banner |
| `BannerLineDelay` | `8` | Milliseconds between lines; `0` prints at once |
| `BannerWait` | `300` | Longest wait, in ms, for an unfinished part at the end |
| `BannerClear` | `$true` | Clear the screen before the first line; `$false` keeps scrollback |

All four go in `$script:DFConfigKeys`.

## Tools and data

- New record `Tools/smartmontools.json` (executable `smartctl`, scoop `smartmontools`, winget
  `smartmontools.smartmontools`), and `Tools/smartmontools.banner.ps1`.
- `Tools/fastfetch.banner.ps1`: captures fastfetch and fetches the public IP.
- fastfetch and smartmontools join `+core`.
- `Tools/fastfetch/config.jsonc` (the seeded default): drop `packages` and `physicaldisk`; add the two
  placeholders. An existing user config is never rewritten; the guide says how to get the new default
  (`Invoke-DFToolSetup fastfetch -Force`) or add the placeholder lines.

## Failure handling

- A part that throws: its lines are left out, with one warning; the banner still prints.
- No network: the IP lookup times out in the background (2 s); the cached value or nothing shows.
- smartctl output that doesn't parse: that drive is left out.
- The banner never throws out of `Start-DFSession`.

## Testing

- Core: placeholder fill (single line, multi line, missing value removes the line), wait budget and cache
  fallback (mocked parts), line delay 0, non-interactive host prints nothing, a throwing part.
- smartmontools part: recorded `smartctl -j` outputs for NVMe, SATA SSD and HDD (from this machine) in
  `tests/fixtures/smartctl/`, through the parser; red-line conditions; no real smartctl in tests.
- fastfetch part: recorded output; no real fastfetch or network in tests.
- Doc examples marked `<!-- system -->` where they'd run real tools.

## Docs

`docs/guide/configuration.md` (the three settings and the banner), `docs/guide/tools.md` (smartmontools),
`docs/guide/writing-a-tool.md` (the `banner` field), CHANGELOG, reference.

## Out of scope

- Drive letters on drive lines (Windows' lookup is ~2.6 s).
- A banner without fastfetch beyond the first line.
- Changing the user's profile (they remove their own `Clear-Host` / `FastFetch` lines).
