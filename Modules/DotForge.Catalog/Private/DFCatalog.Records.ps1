#Requires -Version 7.2

# Constructors for the catalog record types: DotForge.ToolSourceInfo (one
# catalog's view of a package), DotForge.ToolInfo (the merged, cross-catalog
# row trifle returns) and DotForge.ToolSourceDetail (detail-endpoint data).

function New-DFToolSourceInfo {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolSourceInfo — one catalog's view of a package.
    .DESCRIPTION
        Each parameter becomes the property of the same name.
    .PARAMETER Source
        Catalog name: scoop, winget, choco, npm, pypi, crates or psgallery.
    .PARAMETER PackageId
        The package's id in that catalog (e.g. BurntSushi.ripgrep.MSVC).
    .PARAMETER Name
        Display name.
    .PARAMETER Description
        One-line description, when the catalog has one.
    .PARAMETER LatestVersion
        Newest version the catalog offers.
    .PARAMETER InstalledVersion
        Version installed through this catalog, if any.
    .PARAMETER Installed
        Set when the package is installed through this catalog.
    .PARAMETER Homepage
        Project homepage URL.
    .PARAMETER License
        License name or SPDX id.
    .PARAMETER PublishedAt
        When the latest version was published, when known.
    .PARAMETER MatchKind
        How the query matched: exact-id, exact-name or keyword.
    .PARAMETER CacheTimestamp
        When this row was fetched; $null for live data.
    .PARAMETER CacheAgeMinutes
        Age of the cached row in minutes.
    .OUTPUTS
        PSCustomObject (DotForge.ToolSourceInfo).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [string]$LatestVersion,
        [string]$InstalledVersion,
        [switch]$Installed,
        [string]$Homepage,
        [string]$License,
        [nullable[datetime]]$PublishedAt,
        [Parameter(Mandatory)]
        [ValidateSet('exact-id', 'exact-name', 'keyword')]
        [string]$MatchKind,
        [nullable[datetime]]$CacheTimestamp,
        [int]$CacheAgeMinutes
    )

    [pscustomobject]@{
        PSTypeName       = 'DotForge.ToolSourceInfo'
        Source           = $Source
        PackageId        = $PackageId
        Name             = $Name
        Description      = $Description
        LatestVersion    = $LatestVersion
        InstalledVersion = $InstalledVersion
        Installed        = [bool]$Installed
        Homepage         = $Homepage
        License          = $License
        PublishedAt      = $PublishedAt
        MatchKind        = $MatchKind
        CacheTimestamp   = $CacheTimestamp
        CacheAgeMinutes  = $CacheAgeMinutes
    }
}

function New-DFToolInfo {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolInfo — the merged, cross-catalog view emitted
        by Find-DFPackage.
    .DESCRIPTION
        Each parameter becomes the property of the same name. This is the
        object trifle -AsObject returns.
    .PARAMETER Name
        Display name of the merged tool.
    .PARAMETER Description
        First non-empty description across sources.
    .PARAMETER Installed
        Set when any catalog reports it installed.
    .PARAMETER InstalledVia
        Catalogs it is installed through, or 'PATH' when an exact match is on PATH but in no catalog.
    .PARAMETER InstalledVersion
        Installed version (from the first installing catalog).
    .PARAMETER Sources
        One DotForge.ToolSourceInfo per catalog that carries the tool.
    .PARAMETER Latest
        Catalog name -> latest version, in display order.
    .PARAMETER Homepage
        Project homepage URL.
    .PARAMETER License
        License name or SPDX id.
    .PARAMETER DFTool
        Name of the matching Tools/*.json record, when DotForge knows the tool.
    .PARAMETER MatchKind
        Strongest match kind across sources: exact-id, exact-name or keyword.
    .PARAMETER CacheAge
        Age in minutes of the oldest cached source row.
    .PARAMETER Details
        Catalog name -> DotForge.ToolSourceDetail, filled in on the detail path.
    .PARAMETER GitHub
        GitHub stars/release/activity, filled in by -GitInfo.
    .PARAMETER Category
        Taxonomy entry (categories, related tools) from the category database.
    .OUTPUTS
        PSCustomObject (DotForge.ToolInfo).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [switch]$Installed,
        [string[]]$InstalledVia = @(),
        [string]$InstalledVersion,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sources,
        [System.Collections.Specialized.OrderedDictionary]$Latest,
        [string]$Homepage,
        [string]$License,
        [string]$DFTool,
        [string]$MatchKind,
        [int]$CacheAge,
        [System.Collections.Specialized.OrderedDictionary]$Details,
        [object]$GitHub,
        [object]$Category
    )

    [pscustomobject]@{
        PSTypeName       = 'DotForge.ToolInfo'
        Name             = $Name
        Description      = $Description
        Installed        = [bool]$Installed
        InstalledVia     = $InstalledVia
        InstalledVersion = $InstalledVersion
        Sources          = @($Sources)
        Latest           = $Latest
        Homepage         = $Homepage
        License          = $License
        DFTool           = $DFTool
        MatchKind        = $MatchKind
        CacheAge         = $CacheAge
        Details          = $Details
        GitHub           = $GitHub
        Category         = $Category
    }
}

function New-DFToolSourceDetail {
    <#
    .SYNOPSIS
        Constructs a DotForge.ToolSourceDetail — one catalog's deep view of a
        package (detail-endpoint data, beyond what search returns).
    .DESCRIPTION
        Each parameter becomes the property of the same name. Fields a catalog
        doesn't provide stay empty.
    .PARAMETER Source
        Catalog name.
    .PARAMETER PackageId
        The package's id in that catalog.
    .PARAMETER Publisher
        Publisher or author.
    .PARAMETER Maintainers
        Maintainer names.
    .PARAMETER Dependencies
        Declared dependency ids.
    .PARAMETER Tags
        Catalog tags or keywords.
    .PARAMETER Downloads
        Download count, when the catalog reports one.
    .PARAMETER ReleaseNotes
        Release notes text.
    .PARAMETER ReleaseNotesUrl
        Release notes URL.
    .PARAMETER RepositoryUrl
        Source repository URL.
    .PARAMETER DocsUrl
        Documentation URL.
    .PARAMETER InstallHint
        Catalog-specific install command or note.
    .PARAMETER Notes
        Free-form notes (e.g. scoop manifest notes).
    .PARAMETER Readme
        Readme text, filled in by -Readme.
    .PARAMETER Extra
        Other catalog-specific fields, name -> value.
    .OUTPUTS
        PSCustomObject (DotForge.ToolSourceDetail).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Publisher,
        [string[]]$Maintainers = @(),
        [string[]]$Dependencies = @(),
        [string[]]$Tags = @(),
        [nullable[long]]$Downloads,
        [string]$ReleaseNotes,
        [string]$ReleaseNotesUrl,
        [string]$RepositoryUrl,
        [string]$DocsUrl,
        [string]$InstallHint,
        [string]$Notes,
        [string]$Readme,
        [System.Collections.Specialized.OrderedDictionary]$Extra
    )

    [pscustomobject]@{
        PSTypeName      = 'DotForge.ToolSourceDetail'
        Source          = $Source
        PackageId       = $PackageId
        Publisher       = $Publisher
        Maintainers     = $Maintainers
        Dependencies    = $Dependencies
        Tags            = $Tags
        Downloads       = $Downloads
        ReleaseNotes    = $ReleaseNotes
        ReleaseNotesUrl = $ReleaseNotesUrl
        RepositoryUrl   = $RepositoryUrl
        DocsUrl         = $DocsUrl
        InstallHint     = $InstallHint
        Notes           = $Notes
        Readme          = $Readme
        Extra           = $Extra
    }
}
