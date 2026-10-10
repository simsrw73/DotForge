# Modules needed to develop DotForge, not to use it: users need none of these, so
# they are not RequiredModules in DotForge.psd1. Exact versions, so a new release
# can't change what the tests run against. Install with build/Install-DFDevDependencies.ps1;
# CI does the same (.github/workflows/test.yml).
@{
    # The test framework. Pester 6 only (CLAUDE.md, Testing).
    'Pester'          = '6.2.0'
    # The package-universe build pipeline (build/Private/DFPackageUniverse.*) and its tests.
    'PSSQLite'        = '1.1.0'
    'powershell-yaml' = '0.4.12'
}
