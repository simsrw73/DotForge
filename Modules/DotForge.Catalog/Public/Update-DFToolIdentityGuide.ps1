#Requires -Version 7.2

function Update-DFToolIdentityGuide {
    <#
    .SYNOPSIS
        Downloads the latest published trifle tool-identity guide and
        installs it under $XDG_DATA_HOME/dotforge/, taking precedence over
        the module's shipped copy on the next load.
    .DESCRIPTION
        Purely opt-in — never runs implicitly, not part of Update-DFPackageCache,
        not triggered by any trifle/ftrifle call. Cross-catalog identity
        resolution stays fully usable offline with the shipped seed guide by
        default (and always falls back further to the live Tools/*.json
        mechanism regardless of guide state). Validates the download before
        writing; a failed download or a failed validation leaves any existing
        refreshed copy untouched and warns instead of throwing.

        Downloads tool-identities.json from the latest DotForge GitHub release
        and writes $XDG_DATA_HOME\dotforge\tool-identities.json (atomically,
        through a temp file). Delete that file to go back to the shipped copy.
        Supports -WhatIf and -Confirm.
    .EXAMPLE
        Update-DFToolIdentityGuide

        Fetches and installs the latest published tool-identity guide.
    .EXAMPLE
        Update-DFToolIdentityGuide -WhatIf

        Shows what would be written without touching disk.
    .OUTPUTS
        None. Writes one line to the host on success.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/package-catalog.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Update-DFReleaseData -FileName 'tool-identities.json' -Validator 'Test-DFToolIdentityGuideSchema' `
        -Label 'tool-identity guide' -Cmdlet $PSCmdlet
}
