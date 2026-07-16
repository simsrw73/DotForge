#Requires -Version 7.0

# winget-pkgs manifest layout (verified against the live repo, e.g.
# manifests/m/Microsoft/VisualStudioCode/<version>/):
#   - Multi-file (the common format today): <PackageIdentifier>.yaml is the
#     *version* manifest (ManifestType: version, carries DefaultLocale: <tag>),
#     <PackageIdentifier>.installer.yaml is skipped (not needed), and EVERY
#     locale file is tagged, including the default one:
#     <PackageIdentifier>.locale.<BCP47Tag>.yaml (ManifestType: defaultLocale
#     for the one matching DefaultLocale). There is no untagged
#     <PackageIdentifier>.locale.yaml file.
#   - Singleton (an older, now-deprecated format still present for some
#     packages): a single <PackageIdentifier>.yaml with ManifestType:
#     singleton holding installer and locale fields together.
# The "root" file (matches *.yaml, not *.installer.yaml, not *.locale.*.yaml)
# is read first to decide which of the two shapes applies.

function Select-DFPackageUniverseWingetLatestVersion {
    <#
    .SYNOPSIS
        Picks the latest version-folder path from a set, comparing names via
        [version] where they parse cleanly and falling back to ordinal string
        comparison otherwise (winget versions aren't strictly semver).
    .PARAMETER VersionFolders
        Full paths to version folders (leaf name is the version string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$VersionFolders
    )

    if ($VersionFolders.Count -eq 0) { return $null }

    # Iterate the whole set (not $VersionFolders[1..]) — the slice form is
    # $VersionFolders[1..0] for a single-version package, which walks a bogus
    # descending range and throws an out-of-bounds index under Set-StrictMode.
    # The first iteration compares $best against itself, which is harmless.
    $best = $VersionFolders[0]
    foreach ($path in $VersionFolders) {
        $bestName = Split-Path $best -Leaf
        $name = Split-Path $path -Leaf

        $bestVersion = $null
        $version = $null
        if ([version]::TryParse($bestName, [ref]$bestVersion) -and [version]::TryParse($name, [ref]$version)) {
            if ($version -gt $bestVersion) { $best = $path }
        } elseif ([string]::CompareOrdinal($name, $bestName) -gt 0) {
            $best = $path
        }
    }
    $best
}

function Test-DFPackageUniverseWingetIsVersionFolder {
    <#
    .SYNOPSIS
        A directory is a version folder if it holds at least one *.yaml file
        directly and has no subdirectories of its own.
    .PARAMETER Path
        Directory to test.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $hasYaml = @(Get-ChildItem -Path $Path -Filter '*.yaml' -File -ErrorAction Ignore).Count -gt 0
    $hasSubdir = @(Get-ChildItem -Path $Path -Directory -ErrorAction Ignore).Count -gt 0
    $hasYaml -and -not $hasSubdir
}

function Get-DFPackageUniverseWingetPackageDirectories {
    <#
    .SYNOPSIS
        Walks <SnapshotRoot>/manifests/<letter>/... to find package
        directories: a directory whose immediate children are all version
        folders. Handles both 2-segment (Publisher/Package) and deeper
        dotted identifiers (Publisher/Package/SubPackage/...).
    .PARAMETER SnapshotRoot
        Directory directly containing manifests/ (already normalized past
        any GitHub zipball wrapper folder).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotRoot
    )

    $manifestsRoot = Join-Path $SnapshotRoot 'manifests'
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $manifestsRoot)) { return $result }

    function Find-DFPackageUniverseWingetPackageDir {
        param([string]$Dir, $Accumulator)

        $subdirs = @(Get-ChildItem -Path $Dir -Directory -ErrorAction Ignore)
        if ($subdirs.Count -eq 0) { return }

        # Partition children into version folders vs. everything else. A dir is
        # normally cleanly one or the other, but a "mixed" dir (some version
        # folders AND some sub-package dirs) must not silently drop the version
        # folders — emit them as their own package dir here, and still recurse
        # into the non-version children. Recursing into a version folder would
        # lose it (it has no subdirs, so the recursion returns immediately).
        $versionChildren = [System.Collections.Generic.List[string]]::new()
        $otherChildren = [System.Collections.Generic.List[object]]::new()
        foreach ($s in $subdirs) {
            if (Test-DFPackageUniverseWingetIsVersionFolder -Path $s.FullName) {
                $versionChildren.Add($s.FullName)
            } else {
                $otherChildren.Add($s)
            }
        }

        if ($versionChildren.Count -gt 0) {
            $Accumulator.Add([pscustomobject]@{ Path = $Dir; VersionFolders = @($versionChildren) })
        }
        foreach ($s in $otherChildren) {
            Find-DFPackageUniverseWingetPackageDir -Dir $s.FullName -Accumulator $Accumulator
        }
    }

    foreach ($letterDir in Get-ChildItem -Path $manifestsRoot -Directory -ErrorAction Ignore) {
        Find-DFPackageUniverseWingetPackageDir -Dir $letterDir.FullName -Accumulator $result
    }

    $result
}

function ConvertFrom-DFPackageUniverseWingetLocaleYaml {
    <#
    .SYNOPSIS
        Parses one winget defaultLocale or singleton manifest's YAML text
        into row fields. Both shapes carry the same field names
        (PackageName, Publisher, ShortDescription/Description, PackageUrl,
        License, Tags).
    .PARAMETER YamlText
        Raw YAML manifest text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$YamlText
    )

    # INDEX access, not dot access. ConvertFrom-Yaml returns a Hashtable, and
    # $content.Tags on a manifest that declares no Tags THROWS under strict mode
    # ("The property 'Tags' cannot be found"), whereas $content['Tags'] returns
    # $null. Most of these fields are optional in the winget schema: a live run
    # on 2026-07-15 lost 4,734 of 13,763 packages (~34%) to exactly this, each
    # one skipped with a logged warning rather than crashing the run — data loss
    # that looked like a clean run apart from the row count.
    $content = ConvertFrom-Yaml $YamlText
    if (-not $content) { return $null }

    # @() wraps the WHOLE pipeline: `@(x) | Where-Object` yields $null when
    # nothing survives, and $tags.Count then throws under strict.
    $tags = @(@($content['Tags']) | Where-Object { $_ })
    $shortDescription = [string]$content['ShortDescription']
    $description = $shortDescription ? $shortDescription : [string]$content['Description']

    [pscustomobject]@{
        name        = [string]$content['PackageName']
        publisher   = [string]$content['Publisher']
        description = $description
        homepage    = [string]$content['PackageUrl']
        license     = [string]$content['License']
        tags        = $tags.Count -gt 0 ? (ConvertTo-Json -Compress -InputObject @($tags)) : $null
    }
}

function Resolve-DFPackageUniverseWingetVersionRow {
    <#
    .SYNOPSIS
        Resolves one package's latest-version folder to a raw_packages row.
        Logs a 'review' row (per the design spec) when no default-locale
        manifest or singleton manifest can be found, rather than throwing.
    .PARAMETER VersionDir
        Path to the latest version folder for one package.
    .PARAMETER Log
        Scriptblock: param($Level, $PackageId, $Message) -> logs to
        pipeline_log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VersionDir,

        [Parameter(Mandatory)]
        [scriptblock]$Log
    )

    $yamlFiles = @(Get-ChildItem -Path $VersionDir -Filter '*.yaml' -File -ErrorAction Ignore)
    $rootFile = $yamlFiles | Where-Object {
        $_.Name -notmatch '\.installer\.yaml$' -and $_.Name -notmatch '\.locale\.[^.]+\.yaml$'
    } | Select-Object -First 1

    if (-not $rootFile) {
        & $Log 'review' $null "winget: no root manifest file found in $VersionDir"
        return $null
    }

    $rootText = Get-Content $rootFile.FullName -Raw
    $rootContent = ConvertFrom-Yaml $rootText
    if (-not $rootContent) {
        & $Log 'review' $null "winget: root manifest parsed to nothing ($VersionDir)"
        return $null
    }
    # Index access throughout — see ConvertFrom-DFPackageUniverseWingetLocaleYaml.
    $packageId = [string]$rootContent['PackageIdentifier']
    $version = [string]$rootContent['PackageVersion']
    $manifestType = [string]$rootContent['ManifestType']

    $fieldsText =
        if ($manifestType -eq 'singleton') {
            $rootText
        } else {
            $defaultLocale = [string]$rootContent['DefaultLocale']
            if (-not $defaultLocale) {
                & $Log 'review' $packageId "winget: no DefaultLocale declared in version manifest ($VersionDir)"
                return $null
            }
            $localeFile = Join-Path $VersionDir "$packageId.locale.$defaultLocale.yaml"
            if (-not (Test-Path $localeFile)) {
                & $Log 'review' $packageId "winget: no default-locale manifest ($defaultLocale) found ($VersionDir)"
                return $null
            }
            Get-Content $localeFile -Raw
        }
    if ($null -eq $fieldsText) { return $null }

    $fields = ConvertFrom-DFPackageUniverseWingetLocaleYaml -YamlText $fieldsText

    [pscustomobject]@{
        source      = 'winget'
        package_id  = $packageId
        name        = $fields.name
        version     = $version
        description = $fields.description
        homepage    = $fields.homepage
        license     = $fields.license
        publisher   = $fields.publisher
        tags        = $fields.tags
        extra       = $null
        fetched_at  = [datetime]::UtcNow.ToString('o')
    }
}

function Get-DFPackageUniverseWingetRows {
    <#
    .SYNOPSIS
        Acquires raw_packages rows for every package in a winget-pkgs
        manifest snapshot: latest version only, per the design spec.
    .PARAMETER WingetPkgsSnapshot
        Path to an already-downloaded/extracted snapshot (directly containing
        manifests/). This IS the test seam — passing a fixture directory
        skips FetchSnapshot (and any network access) entirely.
    .PARAMETER FetchSnapshot
        Scriptblock: param() -> snapshot root path. Only invoked when
        WingetPkgsSnapshot is omitted.
    .PARAMETER Log
        Scriptblock: param($Level, $PackageId, $Message) -> logs to
        pipeline_log.
    .PARAMETER Trace
        Optional scriptblock: param($Message) -> verbose file-log line.
        Winget can span tens of thousands of packages; progress is emitted
        here so a long run is visibly alive and a failure is locatable.
    #>
    [CmdletBinding()]
    param(
        [string]$WingetPkgsSnapshot,

        [Parameter(Mandatory)]
        [scriptblock]$FetchSnapshot,

        [Parameter(Mandatory)]
        [scriptblock]$Log,

        [scriptblock]$Trace = { }
    )

    $snapshotRoot = $WingetPkgsSnapshot
    if (-not $snapshotRoot) {
        & $Trace 'no snapshot path supplied; downloading a fresh winget-pkgs snapshot'
        $snapshotRoot = & $FetchSnapshot
    }

    if (-not $snapshotRoot -or -not (Test-Path $snapshotRoot)) {
        & $Log 'error' $null 'winget: no snapshot available (download failed or path missing)'
        return @()
    }

    & $Trace "enumerating package directories under $snapshotRoot"
    $packageDirs = @(Get-DFPackageUniverseWingetPackageDirectories -SnapshotRoot $snapshotRoot)
    if ($packageDirs.Count -eq 0) {
        & $Log 'error' $null "winget: no package manifests found under $snapshotRoot"
        return @()
    }
    & $Trace "found $($packageDirs.Count) package directories; resolving latest-version manifests"

    $processed = 0
    $emitted = 0
    foreach ($pkgDir in $packageDirs) {
        $processed++
        if ($processed % 1000 -eq 0) {
            & $Trace "progress: $processed/$($packageDirs.Count) package dirs processed, $emitted rows so far"
        }

        $latestVersionDir = Select-DFPackageUniverseWingetLatestVersion -VersionFolders $pkgDir.VersionFolders
        if (-not $latestVersionDir) { continue }

        try {
            $row = Resolve-DFPackageUniverseWingetVersionRow -VersionDir $latestVersionDir -Log $Log
            if ($row) { $emitted++; $row }
        } catch {
            & $Log 'warning' $null "winget: failed to parse manifest in ${latestVersionDir}: $_"
        }
    }

    & $Trace "winget acquisition finished: $emitted rows from $($packageDirs.Count) package directories"
}
