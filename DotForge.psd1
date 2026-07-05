@{
    ModuleVersion     = '0.3.0'
    GUID              = '160e0d4a-5e2d-4c49-9ec2-562fbdb72b71'
    Author            = 'Randy W. Sims'
    CompanyName       = ''
    Copyright         = '(c) Randy W. Sims. All rights reserved.'
    Description       = 'Framework for registering and configuring CLI tools in a PowerShell profile — XDG paths, PATH management, fzf pickers, and aliases.'
    PowerShellVersion    = '7.0'
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
        'Update-DFCategoryDb'
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
        'copy', 'paste',
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
            ReleaseNotes = 'Preview release. Registers and configures 32+ CLI tools from a JSON database — XDG path compliance, fzf pickers, aliases, and per-tool companion scripts. New in 0.3.0: New-DFUuid (uuidgen) — v4 UUID generator with composable -UpperCase/-NoHyphens/-Braces switches and an -Sdk preset; Get-DFEnv (env) now renders colorized, pipe-safe KEY=VALUE output. Carries forward: clh/clhp (Show-DFCliHelp) colorized external CLI help with cached flag detection, PSReadLine color theme system (dark/light/catppuccin-mocha + live fprl picker), .cmd shim generation (New-DFShim) for off-PATH executables, dependency-ordered tool registration via dependsOn, and 33 exported cmdlets plus general-purpose profile helpers (navigation, process, clipboard, environment).'
        }
    }
}
