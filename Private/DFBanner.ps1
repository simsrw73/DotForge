#Requires -Version 7.2

# The startup banner's coordinator (ShowBanner). Core never names a tool: parts
# come from requested, installed tools whose records have a banner field. A
# part script (Tools/<tool>.banner.ps1) is dot-sourced here, so its script
# blocks can call DotForge's private helpers; it outputs one object:
#   Style    { param($Context) }           -> @{ KeyColor; OutputColor; Separator } (optional)
#   Work     { param($Context) }           -> background jobs: @{ Name; ScriptBlock; ArgumentList }
#   Complete { param($Results, $Context) } -> @{ Body = lines or $null; Fills = @{ name = items } }
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

$script:DFBannerShown = $false

function Test-DFBannerHost {
    <#
    .SYNOPSIS
        Whether the banner may print: an interactive console host whose output isn't redirected.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    (Test-DFInteractiveHost) -and -not [Console]::IsOutputRedirected
}

function Get-DFBannerCachePath {
    <#
    .SYNOPSIS
        The banner's last known fills: $XDG_CACHE_HOME\dotforge\banner.json.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-DFXdgPath Cache) 'dotforge' 'banner.json'
}

function Start-DFBanner {
    <#
    .SYNOPSIS
        With ShowBanner on, clears the screen, prints the first line, and starts every banner part's background work.
    .DESCRIPTION
        Returns the state Show-DFBanner needs, or $null when the banner is
        off, the host isn't interactive, or it was already shown in this
        shell. Never throws.
    .PARAMETER Tools
        The requested tool names.
    .OUTPUTS
        pscustomobject (Parts, Style, Handle), or $null.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Tools)
    if (-not (Get-DFConfig ShowBanner -Default $false) -or $script:DFBannerShown -or -not (Test-DFBannerHost)) { return }
    $script:DFBannerShown = $true
    try {
        if (Get-DFConfig BannerClear -Default $true) { Clear-Host }
        $parts = @(Get-DFBannerPart -Tools $Tools)
        $style = Get-DFBannerPartStyle -Parts $parts
        $version = $ExecutionContext.SessionState.Module.Version
        $firstLine = Format-DFBannerLine -Key 'DotForge' -Value "$(if ($version) { "$version · " })loading $(@($Tools).Count) tools…" -Style $style
        Write-DFBannerLines -Lines @($firstLine) -DelayMs 0
        $work = @(foreach ($part in $parts) {
            try { & $part.Script.Work $part.Context }
            catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed to start: $($_.Exception.Message)" }
        })
        [pscustomobject]@{ Parts = $parts; Style = $style; Handle = (Start-DFBannerWork -Work $work) }
    } catch {
        Write-Warning "DotForge: the banner failed to start: $($_.Exception.Message)"
    }
}

function Get-DFBannerPart {
    <#
    .SYNOPSIS
        Loads the banner parts of the requested, installed tools with a banner field; the body part first.
    .PARAMETER Tools
        The requested tool names.
    .OUTPUTS
        pscustomobject per part: Tool, Context, Script (Style, Work, Complete).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Tools)
    if (-not $Tools) { return }
    $db = Import-DFToolDb -Name $Tools 3>$null
    $shipped = ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools')
    foreach ($tool in @($db.Values | Where-Object { $_.banner } | Sort-Object { -not $_.banner.body }, name)) {
        if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type)) { continue }
        $path = Join-Path (Get-DFToolFolder -Tool $tool -Default $shipped) $tool.banner.script
        try {
            $script = . $path
            [pscustomobject]@{ Tool = $tool; Context = [pscustomobject]@{ Tool = $tool }; Script = $script }
        } catch { Write-Warning "DotForge: banner part $($tool.name) didn't load: $($_.Exception.Message)" }
    }
}

function Get-DFBannerPartStyle {
    <#
    .SYNOPSIS
        The banner style from the first part that has one; plain otherwise.
    .PARAMETER Parts
        Get-DFBannerPart result.
    .OUTPUTS
        New-DFBannerStyle result.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Parts)
    foreach ($part in $Parts) {
        if (-not $part.Script.PSObject.Properties['Style']) { continue }
        try {
            $values = & $part.Script.Style $part.Context
            if ($values) { return New-DFBannerStyle @values }
        } catch { Write-Verbose "DotForge: banner part $($part.Tool.name) has no style: $($_.Exception.Message)" }
    }
    New-DFBannerStyle
}

function Show-DFBanner {
    <#
    .SYNOPSIS
        Collects the banner parts' results, fills placeholders (from the cache when a part isn't back in time), caches, and prints.
    .PARAMETER State
        Start-DFBanner result; $null does nothing.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param($State)
    if (-not $State) { return }
    try {
        $results = Receive-DFBannerWork -Handle $State.Handle -WaitMs (Get-DFConfig BannerWait -Default 300)
        $body = $null
        $fills = @{}
        foreach ($part in $State.Parts) {
            try {
                $done = & $part.Script.Complete $results $part.Context
                if ($part.Tool.banner.body -and $done.Body) { $body = @($done.Body) }
                if ($done.Fills) {
                    foreach ($name in @($done.Fills.Keys)) { if (@($done.Fills[$name])) { $fills[$name] = @($done.Fills[$name]) } }
                }
            } catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed: $($_.Exception.Message)" }
        }
        $fills = Merge-DFBannerCache -Fills $fills -Names @($State.Parts | ForEach-Object { $_.Tool.banner.fills })
        if ($body) {
            Write-DFBannerLines -Lines @(Merge-DFBannerBody -Body $body -Fills $fills -Style $State.Style) -DelayMs (Get-DFConfig BannerLineDelay -Default 8)
        }
    } catch {
        Write-Warning "DotForge: the banner failed: $($_.Exception.Message)"
    }
}

function Merge-DFBannerCache {
    <#
    .SYNOPSIS
        Saves fresh fills to the cache and fills the missing ones from it, marked "(cached)".
    .PARAMETER Fills
        Fresh fills.
    .PARAMETER Names
        Every fill name the loaded parts declare.
    .OUTPUTS
        System.Collections.Hashtable: name -> fill items.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Fills, [AllowEmptyCollection()][string[]]$Names)
    $cache = Read-DFBannerCache
    $all = @{}
    foreach ($name in $Fills.Keys) {
        $all[$name] = $Fills[$name]
        $cache[$name] = @{ at = [DateTime]::UtcNow.ToString('o'); items = @($Fills[$name]) }
    }
    foreach ($name in $Names) {
        if ($all.ContainsKey($name) -or -not $cache.ContainsKey($name)) { continue }
        $all[$name] = @(foreach ($item in @($cache[$name].items)) {
            [pscustomobject]@{ Key = $item.Key; Value = "$($item.Value) (cached)"; Alert = [bool]$item.Alert }
        })
    }
    if ($Fills.Count) { Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value ($cache | ConvertTo-Json -Depth 6) }
    $all
}

function Read-DFBannerCache {
    <#
    .SYNOPSIS
        The banner's cached fills (name -> @{ at; items }); empty when there are none or the file can't be read.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    param()
    $path = Get-DFBannerCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $cache = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($cache -is [System.Collections.IDictionary]) { return $cache }
    } catch { Write-Verbose "DotForge: the banner cache can't be read: $($_.Exception.Message)" }
    @{}
}
