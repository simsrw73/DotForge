@{
    ModuleVersion     = '0.6.0'
    GUID              = '5b1f7f0e-3a62-4b0e-9d43-7a2a9c1e6f21'
    Author            = 'Randy W. Sims'
    CompanyName       = ''
    Copyright         = '(c) Randy W. Sims. All rights reserved.'
    Description       = 'DotForge package catalog (trifle): search, pick and inspect packages across scoop, winget, choco, npm, crates.io, PyPI and the PowerShell Gallery. Loaded on first use by DotForge.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    RootModule           = 'DotForge.Catalog.psm1'
    FunctionsToExport = @(
        # Catalog Info (trifle)
        'Find-DFPackage',
        'Update-DFPackageCache',
        'Select-DFPackage',
        'Get-DFCategoryList',
        'Update-DFCategoryDb',
        'Update-DFToolIdentityGuide'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    # Aliases (trifle, ftrifle, tcats) are exported by DotForge, so they win over programs of the same name.
    AliasesToExport   = @()
}
