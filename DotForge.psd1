@{
    ModuleVersion     = '0.5.0'
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
            ReleaseNotes = 'Preview release. New in 0.5.0: fuzzy fzf package-manager pickers for winget (wins/wrm/wup), scoop (sins/srm/sup), and choco (cins/crm/cup) — search->install, uninstall, and multi-select update, each with a live preview pane (debounced so fast scrolling does not spawn a preview per skipped item) and multi-key/act-in-place fzf bindings; Ctrl+G W/S/C PSReadLine chords read the current line as a query and drop the resulting install command onto the command line for editing. Package data uses object output (Microsoft.WinGet.Client, the Scoop module) and choco -r machine-readable output instead of table scraping; scoop search uses the fast scoop-search hook. Invoke-DFPicker gains -Expect/-Bind/-FzfArgs; wrm -Source filters installed packages by source. Carries forward: the completion stack (PSReadLine + Carapace + PSFzf + inshellisense), trifle/ftrifle multi-catalog package discovery, fnm per-directory Node switching, clh/clhp colorized CLI help, the PSReadLine color theme system, .cmd shim generation, and dependency-ordered registration via dependsOn.'
        }
    }
}
