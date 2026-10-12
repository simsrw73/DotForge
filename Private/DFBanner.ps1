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
# Set when a Start-DFSession finishes: a later call in the same shell (say, one
# that turns ShowBanner on) never clears the screen of a shell already in use.
$script:DFSessionStarted = $false

function Test-DFBannerHost {
    <#
    .SYNOPSIS
        Whether the banner may print: an interactive console shell (not one started to run a command or script) whose output isn't redirected.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    (Test-DFInteractiveHost) -and -not [Console]::IsOutputRedirected -and (Test-DFReplStart)
}

function Test-DFReplStart {
    <#
    .SYNOPSIS
        Whether pwsh was started as an interactive shell, not to run a command or a script.
    .DESCRIPTION
        `pwsh -c ...`, `pwsh -File x.ps1`, `pwsh x.ps1` and `pwsh -EncodedCommand ...`
        run something and exit, so they get no banner (and don't clear the
        screen of the shell they were typed in), unless -NoExit keeps them
        open. Parameter names may be shortened, as pwsh allows.
    .PARAMETER CommandLine
        The process's arguments, the program first. Default: [Environment]::GetCommandLineArgs().
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$CommandLine = [Environment]::GetCommandLineArgs())
    $isPrefix = { param([string]$Arg, [string]$Name, [int]$Min) $Arg.Length -ge $Min -and $Name.StartsWith($Arg, [StringComparison]::OrdinalIgnoreCase) }
    $runs = $false
    $noExit = $false
    $skipValue = $false
    foreach ($arg in @($CommandLine | Select-Object -Skip 1)) {
        if ($skipValue) { $skipValue = $false; continue }
        if ($arg -notmatch '^[-/](.+)$') { $runs = $true; break }   # a script path
        $name = $Matches[1] -replace ':.*$', ''
        if (& $isPrefix $name 'noexit' 3) { $noExit = $true; continue }
        if ($name -ieq 'c' -or (& $isPrefix $name 'command' 3) -or $name -ieq 'f' -or (& $isPrefix $name 'file' 2) -or
            $name -ieq 'e' -or $name -ieq 'ec' -or (& $isPrefix $name 'encodedcommand' 3)) { $runs = $true; break }
        # Options that take a value: skip the value, so it isn't read as a script path.
        foreach ($valued in 'executionpolicy', 'ep', 'workingdirectory', 'wd', 'windowstyle', 'settingsfile', 'configurationname', 'custompipename', 'inputformat', 'outputformat') {
            if ($name -ieq $valued -or ($valued.Length -gt 3 -and (& $isPrefix $name $valued 3))) { $skipValue = $true; break }
        }
    }
    -not $runs -or $noExit
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
    if (-not (Get-DFConfig ShowBanner -Default $false) -or $script:DFBannerShown -or $script:DFSessionStarted -or -not (Test-DFBannerHost)) { return }
    $script:DFBannerShown = $true
    try {
        if (Get-DFConfig BannerClear -Default $true) { Clear-Host }
        $parts = @(Get-DFBannerPart -Tools $Tools)
        $style = Get-DFBannerPartStyle -Parts $parts
        $module = $ExecutionContext.SessionState.Module
        $version = if ($module) { $module.Version }
        $firstLine = Format-DFBannerLine -Key 'DotForge' -Value "$(if ($version) { "$version · " })loading $(@($Tools).Count) tools…" -Style $style
        Write-DFBannerLines -Lines @($firstLine) -DelayMs 0
        $work = @(foreach ($part in @(Select-DFBannerWorkPart -Parts $parts)) {
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

function Select-DFBannerWorkPart {
    <#
    .SYNOPSIS
        The parts whose background work something will show: none without a body part; otherwise the body part and the parts filling a placeholder it uses.
    .DESCRIPTION
        A body part may say which placeholders its body has (Uses); without
        Uses every fill counts as used.
    .PARAMETER Parts
        Get-DFBannerPart result.
    .OUTPUTS
        The parts to start.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Parts)
    $body = @($Parts | Where-Object { $_.Tool.banner.body })
    if (-not $body) { return }
    $used = $null
    foreach ($part in $body) {
        if (-not $part.Script.PSObject.Properties['Uses']) { continue }
        try { $used = @($used) + @(& $part.Script.Uses $part.Context) | Where-Object { $_ } } catch { $used = $null; break }
    }
    foreach ($part in $Parts) {
        if ($part.Tool.banner.body -or $null -eq $used) { $part; continue }
        if (@($part.Tool.banner.fills | Where-Object { $_ -in $used })) { $part }
    }
}

function Set-DFBannerSessionStarted {
    <#
    .SYNOPSIS
        Records that this shell's first Start-DFSession has run, so no later call shows a banner.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()
    $script:DFSessionStarted = $true
}

function Stop-DFBanner {
    <#
    .SYNOPSIS
        Lets the banner's background work end without showing it (the load failed or was stopped).
    .PARAMETER State
        Start-DFBanner result; $null does nothing.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param($State)
    if (-not $State -or -not $State.PSObject.Properties['Handle'] -or -not $State.Handle.Pool) { return }
    try { $null = $State.Handle.Pool.BeginClose($null, $null) } catch { Write-Verbose "DotForge: $($_.Exception.Message)" }
}

function ConvertTo-DFBannerFillItem {
    <#
    .SYNOPSIS
        The well-formed fill items (Key, Value, Alert) among what a part or the cache gave; the rest are dropped.
    .PARAMETER Items
        Candidate items.
    .OUTPUTS
        pscustomobject per item: Key, Value, Alert.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Items)
    foreach ($item in @($Items)) {
        $get = if ($item -is [System.Collections.IDictionary]) { { param($n) if ($item.Contains($n)) { $item[$n] } } }
               elseif ($item -is [psobject] -and $item -isnot [string] -and $item -isnot [ValueType]) { { param($n) $item.PSObject.Properties[$n]?.Value } }
               else { $null }
        if (-not $get) { continue }
        $value = & $get 'Value'
        if ($null -eq $value) { continue }
        [pscustomobject]@{ Key = (& $get 'Key'); Value = "$value"; Alert = [bool](& $get 'Alert') }
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
                $doneBody = if ($done -is [psobject]) { $done.PSObject.Properties['Body']?.Value }
                $doneFills = if ($done -is [psobject]) { $done.PSObject.Properties['Fills']?.Value }
                if ($part.Tool.banner.body -and $doneBody) { $body = @($doneBody | ForEach-Object { "$_" }) }
                if ($doneFills -is [System.Collections.IDictionary]) {
                    foreach ($name in @($doneFills.Keys)) {
                        $items = @(ConvertTo-DFBannerFillItem -Items @($doneFills[$name]))
                        if ($items) { $fills[$name] = $items }
                    }
                }
            } catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed: $($_.Exception.Message)" }
        }
        $fills = Merge-DFBannerCache -Fills $fills -Names @($State.Parts | ForEach-Object { $_.Tool.banner.fills })
        if ($body) {
            Write-DFBannerLines -Lines @(Merge-DFBannerBody -Body $body -Fills $fills -Style $State.Style) -DelayMs (Get-DFConfig BannerLineDelay -Default 8)
        } else {
            $late = @($State.Parts | Where-Object { $_.Tool.banner.body } | ForEach-Object { $_.Tool.name })
            if ($late) {
                $wait = Get-DFConfig BannerWait -Default 300
                Write-DFBannerLines -Lines @(Format-DFBannerLine -Key 'DotForge' -Value "$($late -join ', ') wasn't ready within BannerWait ($wait ms); raise BannerWait or make it faster" -Style $State.Style) -DelayMs 0
            }
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
        $entry = $cache[$name]
        $cached = if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('items') -and $entry['items'] -is [System.Collections.IList]) { @(ConvertTo-DFBannerFillItem -Items @($entry['items'])) }
        if (-not $cached) { continue }
        $all[$name] = @(foreach ($item in $cached) { [pscustomobject]@{ Key = $item.Key; Value = "$($item.Value) (cached)"; Alert = $item.Alert } })
    }
    if ($Fills.Count) { Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value ($cache | ConvertTo-Json -Depth 6) }
    $all
}

function Complete-DFBannerBody {
    <#
    .SYNOPSIS
        Fills a body's @DF:<name>@ placeholders from the banner cache (values marked "(cached)") and removes the rest.
    .DESCRIPTION
        For a banner-style body printed outside the startup banner, such as
        fastfetch run by hand, so placeholder text never shows.
    .PARAMETER Body
        The lines.
    .PARAMETER StyleValues
        KeyColor, OutputColor and Separator for New-DFBannerStyle.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Body, [hashtable]$StyleValues = @{})
    $names = @(foreach ($line in $Body) { if ($line -match '@DF:([\w-]+)@') { $Matches[1] } })
    if (-not $names) { return $Body }
    $fills = Merge-DFBannerCache -Fills @{} -Names $names
    Merge-DFBannerBody -Body $Body -Fills $fills -Style (New-DFBannerStyle @StyleValues)
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
