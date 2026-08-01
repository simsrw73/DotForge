# gsudo sudo precedence design

## Goal

Ensure DotForge uses gsudo when Windows' built-in `sudo.exe` is earlier on `PATH`.

## Design

`Tools/gsudo.ps1` owns gsudo precedence and the `sudo -> gsudo` alias. It resolves `gsudo.exe` through any installed shim, inspects every installed `sudo` executable, and prepends gsudo's resolved directory only when Windows' built-in `sudo.exe` wins.

Tools that need elevation depend on the gsudo record and call `sudo`, never `gsudo`. This makes the alias the PowerShell entry point while the reordered PATH also gives child processes gsudo's `sudo.exe` shim.

The adjustment is deliberately conditional: unrelated tools and installations where another `sudo` wins remain unchanged. `Add-DFToPath -Prepend` normalizes, deduplicates, and moves an existing directory to the front.

## Error handling and tests

If gsudo cannot be resolved, normal availability handling skips the companion and elevation consumers fall back to their native behavior. Pester regression tests simulate a Scoop shim behind Windows `sudo.exe`, assert the shim becomes first in `PATH`, and assert the global `sudo` alias targets gsudo.
