# Choosing a manager: InstallAlways and bad sources

**Status:** design, for review. 2026-10-25. Piece 5 of the restore notes.
**Context:** `docs/superpowers/specs/2026-10-24-restore-install-locations-notes.md`, Decision 5 and
rule 1.

## Why

A record already ranks the sources that suit its tool (`install.prefer`), and the user already has
`InstallOrder` (global order), `InstallVia` (per tool) and `ExcludeSources`. Two things are missing:

- **Rule 1, "the user's overall preference is always honored":** no setting says "use scoop for
  everything". `InstallOrder` only orders, and a record's `install.prefer` beats it.
- **Bad sources:** some sources install a tool in a way DotForge can't fix without fighting the
  manager. From scoop, rustup's installer forces `CARGO_HOME`/`RUSTUP_HOME` to scoop's persist folder,
  and pnpm's post-install saves scoop's paths in pnpm's config. Nothing in a record can say "avoid
  this source for me, and why", so DotForge can't steer around it or tell the user.

## Goals

- `InstallAlways = '<source>'` (session config): every tool a system manager can provide is installed
  from that source, or not at all.
- A record can mark a source as bad for its tool, with a reason. DotForge then ranks that source last,
  and warns with the reason when it installs from it anyway.

## Non-goals

- Warning about a tool already installed from a bad source, at first run: that needs DotForge to know
  which manager installed a tool, which is T-83's work. Add it there.
- Links, and locations that depend on the installing manager: T-83 and piece 6.

## Decided (the user's, 2026-10-25)

1. **Name:** `InstallAlways`.
2. **Strict:** a tool the named source has no package for is **skipped**, not installed from another
   source. It is reported with the reason.
3. **Scope:** only tools some system manager carries. A system manager is a member of the
   `package-manager` role (today scoop, winget, choco). A tool with no package in any system manager
   (PowerShell modules from psresource, npm tools, crates, node from fnm) installs as usual, since no
   system manager could provide it.
4. **Bad source:** ranked last, and a warning when used. DotForge's own order and `InstallOrder` pass
   over it while another source has the tool. When the user forces it (`-Via`, `InstallVia` or
   `InstallAlways`), it installs anyway and warns once, with the record's reason.
5. **When to warn:** at install. First-run warnings belong to T-83.

## Design

### Order

The source order becomes: `-Via`, `InstallVia`, `InstallAlways`, `install.prefer`, `InstallOrder`,
DotForge's order, with avoided sources moved to the end. Only `-Via`, `InstallVia` and `InstallAlways`
put an avoided source back at the front.

`Get-DFInstallSourceOrder` (`Shared/DFInstallSource.ps1`) owns this. For a tool covered by
`InstallAlways` (decision 3), the candidates are `-Via`/`InstallVia` if given, else the
`InstallAlways` source alone. If the tool has no package for it, the order is empty and
`Resolve-DFInstallSource` returns a Gap: `InstallAlways is <source>, which has no package for it`.
The Gap goes into the plan's Gaps and the summary, like today's "no package in any source".

A per-tool `InstallVia` or `-Via` still beats `InstallAlways`: that is the user naming a tool's source,
which is narrower than the global rule.

### Record field: `install.avoid`

```json
"install": { "avoid": { "scoop": "scoop's installer puts toolchains in its own folder, not RUSTUP_HOME" } }
```

An object, source → reason (one sentence, shown to the user). Normalized at load like
`install.prefer`: `install.avoid` is always present (an empty object when absent). A source named both
in `prefer` and `avoid` is a schema error.

First records:
- `rustup`: avoid `scoop` (its installer forces `CARGO_HOME` and `RUSTUP_HOME` to scoop's persist
  folder before `rustup-init`, so toolchains never land in the XDG folders).
- `pnpm`: avoid `scoop` (its post-install saves scoop's store, cache and state folders in pnpm's own
  config, so `PNPM_HOME` alone doesn't move them).

### The warning

When the plan installs a tool from a source its record avoids, the plan output (`Write-DFInstallPlan`)
names it with the reason before anything runs, and the result row's Detail repeats it. One line per
tool per install, never a repeating notice.

### Config

`InstallAlways` goes into `$script:DFConfigKeys` (string, a source name). A value that is not a
known source warns when an install is planned (`Write-DFInstallWarning`, as `InstallVia` does) and is
ignored. If it names a source `ExcludeSources` also
lists, `InstallAlways` wins, with a warning, the same as `InstallVia` does today. *(My call.)*

## Tests

- Source order: `InstallAlways` beats `install.prefer` and `InstallOrder`; `InstallVia` and `-Via`
  beat `InstallAlways`; a tool the source lacks gives the Gap text above; a psresource-only tool
  (no system-manager package) ignores `InstallAlways`; an avoided source goes last under
  `InstallOrder` and DotForge's order, but stays first under `-Via`, `InstallVia` and `InstallAlways`;
  `InstallAlways` naming an excluded source wins and warns; an unknown source warns.
- Record schema: `install.avoid` normalizes to an object; `prefer` and `avoid` naming the same source
  is rejected.
- Plan output and result Detail carry the avoid reason when that source is used.
- rustup and pnpm records avoid scoop.

## Docs

`docs/guide/configuration.md` (settings table, the order list near line 367),
`docs/guide/writing-a-tool.md` (`install.avoid`), `docs/guide/troubleshooting.md` (the new Gap
text), CLAUDE.md's Tool JSON Schema (`install.avoid` beside `install.prefer`), CHANGELOG; and add the
first-run warning to T-83.

## Left to the builder

Helper names, where the avoid reason is stored on the plan item, and the exact warning text.
