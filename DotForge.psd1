@{
    ModuleVersion     = '0.6.0'
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
        'Register-DFTool',
        'Complete-DFToolSetup',
        # Layer 3 — Tool Operations
        'Initialize-DFEnvironment',
        'Install-DFTool',
        'New-DFShim',
        # General Helpers — Help & Discovery
        'Invoke-DFHelp',
        'Show-DFCliHelp',
        'Show-DFCliHelpPaged',
        'Select-DFCommand',
        'Select-DFVerb',
        'Select-DFModule',
        'Select-DFHelpTopic',
        # General Helpers — Navigation
        'Set-DFLocationUp',
        'New-DFDirectoryAndSet',
        'Select-DFLocation',
        # General Helpers — File System
        'New-DFFile',
        'Get-DFWhich',
        'Open-DFItem',
        # General Helpers — Process
        'Select-DFProcess',
        'Get-DFTopProcess',
        # General Helpers — Environment & Profile
        'Get-DFEnv',
        'Get-DFPath',
        'Select-DFEnvVar',
        'Edit-DFProfile',
        'Invoke-DFProfileReload',
        # General Helpers — Clipboard
        'Copy-DFToClipboard',
        'Get-DFFromClipboard',
        # General Helpers — Utility
        'New-DFUuid',
        # Catalog Info (trifle)
        'Find-DFPackage',
        'Update-DFPackageCache',
        'Select-DFPackage',
        'Get-DFCategoryList',
        'Update-DFCategoryDb',
        'Update-DFToolIdentityGuide',
        'Get-DFCommandConflict'
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
            ReleaseNotes = 'Preview release. New in 0.6.0: a 2026-09-06 zsh-parity pass fixed eza''s ll/la aliases and fzf''s match mode/previews to mirror a reference zsh config, defaulted PSReadLine to Emacs edit mode with history relocated under XDG_STATE_HOME (size 10000), and added three tools -- rustup, vcpkg, and direnv (PowerShell hook via LocationChangedAction, needs PS 7.2+). Startup performance: command-output caching for carapace/zoxide/mdcat/scoop-search (~200ms), Test-DFToolAvailable memoization (~44% faster Register-DFTool -All), and background Import-Module pre-warming for module-type tools like PSFzf/Terminal-Icons/posh-git (~77% faster real import). New tool-setup-lifecycle primitive (Tools/<name>.setup.ps1) for one-time persistent setup -- first used to make delta''s catppuccin theme actually render (previously a silent no-op) via a git-config include line, and to stop mdv''s config from being silently rewritten after deletion. New vivid (LS_COLORS theming) and bat (BAT_THEME) plugins; $DFConfig.Defaults lets tools compete for a role (lsd added alongside eza for "listing"). New author-time tool-conformance harness verifies tools actually honor their configuration. Canonical path handling (ConvertTo-DFPath) fixes mixed \/ separators in XDG-derived env vars. New mdcat/mdv markdown viewers; glow''s XDG config now actually takes effect via a wrapper function. Theme resolution is now driven by a shared $DFConfig[''Theme''] key with per-tool overrides and per-tool themeMap translation. The copy alias is renamed to yank (collided with PowerShell''s builtin); all general-helper aliases are now genuinely module-owned. Also fixes a $DFConfig = $null crash across five code paths, real SQL parameter binding in the winget catalog search, New-DFShim resolving relative arguments against the wrong directory, and stale caching in Import-DFToolDb/Resolve-DFPackageManager. Carries forward: fuzzy fzf package-manager pickers (winget/scoop/choco), the completion stack (PSReadLine + Carapace + PSFzf + inshellisense), trifle/ftrifle multi-catalog package discovery, fnm per-directory Node switching, and dependency-ordered registration via dependsOn.'
        }
    }
}
