#Requires -Version 7.0

function Update-DFCategoryDb {
    <#
    .SYNOPSIS
        Downloads the latest published trifle category database and installs
        it under $XDG_DATA_HOME/dotforge/, taking precedence over the module's
        shipped copy on the next load.
    .DESCRIPTION
        Purely opt-in — never runs implicitly, not part of Update-DFPackageCache,
        not triggered by any trifle/ftrifle call. Discovery stays fully usable
        offline with the shipped seed data by default. Validates the download
        before writing; a failed download or a failed validation leaves any
        existing refreshed copy untouched and warns instead of throwing.

        Downloads tool-categories.json from the latest DotForge GitHub release
        and writes $XDG_DATA_HOME\dotforge\tool-categories.json (atomically,
        through a temp file). Delete that file to go back to the shipped copy.
        Supports -WhatIf and -Confirm.
    .EXAMPLE
        Update-DFCategoryDb

        Fetches and installs the latest published category database.
    .EXAMPLE
        Update-DFCategoryDb -WhatIf

        Shows what would be written without touching disk.
    .OUTPUTS
        None. Writes one line to the host on success.
    .LINK
        https://github.com/simsrw73/DotForge/blob/main/docs/guide/package-catalog.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Update-DFReleaseData -FileName 'tool-categories.json' -Validator 'Test-DFCategoryDbSchema' `
        -Label 'category database' -Cmdlet $PSCmdlet
}
