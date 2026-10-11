#Requires -Version 7.2
# DotForge minimal profile
# ─────────────────────────────────────────────────────────────────────────────
# The simplest possible DotForge setup: import, initialize, register everything.
# Good for: getting started, CI environments, shared machines.

Import-Module DotForge

Start-DFSession -Config @{ Tools = @('+core') }  # sets XDG dirs and configures the requested group

# Optional system summary at startup (fastfetch, drive health, public IP), printed
# a line at a time: add ShowBanner = $true to the config. See
# docs/guide/configuration.md#startup-banner.
