@{
    ModuleVersion     = '0.7.0'
    GUID              = '160e0d4a-5e2d-4c49-9ec2-562fbdb72b71'
    Author            = 'Randy W. Sims'
    CompanyName       = ''
    Copyright         = '(c) Randy W. Sims. All rights reserved.'
    Description       = 'Framework for registering and configuring CLI tools in a PowerShell profile — XDG paths, PATH management, fzf pickers, and aliases.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    RootModule           = 'DotForge.psm1'
    FunctionsToExport = @(
        # Layer 1 — Core Primitives
        'Add-DFToPath',
        'New-DFDirectory',
        'Invoke-DFPicker',
        'Invoke-DFWithPager',
        # Layer 2 — Tool Registry
        'Get-DFTool',
        'Find-DFTool',
        'Get-DFRole',
        'Get-DFToolGroup',
        'Start-DFSession',
        'Get-DFConfig',
        'Get-DFToolStatus',
        'Register-DFTool',
        'Complete-DFToolSetup',
        # Layer 3 — Tool Operations
        'Install-DFTool',
        'Invoke-DFToolSetup',
        'New-DFShim',
        'Get-DFCommandConflict'
        # The general helpers and the package catalog are the on-demand modules
        # Modules/DotForge.Helpers and Modules/DotForge.Catalog; their aliases are exported here.
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @(
        'pg',
        'hm', 'clh', 'clhp', 'fcmd', 'fverb', 'fmod', 'fh',
        'up', 'mkcd', 'fcd',
        'touch', 'which', 'open',
        'fps', 'top',
        'env', 'path', 'fenv', 'ep', 'reload',
        'yank', 'paste',
        'uuidgen',
        'trifle', 'ftrifle', 'tcats'
    )
    PrivateData       = @{
        PSData = @{
            Tags         = @('CLI', 'Tools', 'Profile', 'XDG', 'fzf', 'Configuration', 'Windows', 'Shim', 'PSReadLine')
            LicenseUri   = 'https://github.com/simsrw73/DotForge/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/simsrw73/DotForge'
            IconUri      = 'https://raw.githubusercontent.com/simsrw73/DotForge/main/assets/dotforge1.png'
            Prerelease   = 'preview'
            ReleaseNotes = 'Preview release. BREAKING: replace Initialize-DFEnvironment and Register-DFTool -All in your profile with one call, Start-DFSession -Config @{ Tools = @(''+core'', ...) } (see docs/guide/getting-started.md). New in 0.7.0: opt-in tool selection (Tools with +groups, ExcludeTools; only requested, installed tools load, and nothing installs during a load); a missing-tools notice and Get-DFToolStatus; Install-DFTool -Missing installs what the session reported missing as one staged plan (a manager or runtime before what needs it, never anything unrequested), with package managers as plugins (installs blocks) and source choice via InstallVia, install.prefer and InstallOrder; requires/after in tool records (dependsOn removed); tool roles v2 (pager, editor, prompt, project-env, tab completion, js/python runtimes, version managers, package managers); Python and JavaScript toolchains as groups; one-time setup with seeded config files (Invoke-DFToolSetup); public Get-DFConfig; new tools including starship, moor, ov, mise, ps-dotenv, node, bun, pnpm, python, uv, pip and pipx. Import-Module is about 5x faster (the package catalog and general helpers load on first use; the core loads from one bundled file) and startup about a quarter faster. Many fixes: a broken tool no longer stops the rest, atomic cache writes, a stuck winget no longer hangs trifle, cross-catalog matching for cargo/PSGallery packages, and more. Full list in CHANGELOG.md.'
        }
    }
}
