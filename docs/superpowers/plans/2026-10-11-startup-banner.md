# Startup Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShowBanner = $true` clears the screen, prints one line at once, and when `Start-DFSession` ends prints fastfetch's summary with the public IP and one health line per drive, a line at a time.

**Architecture:** Tools declare banner parts (`banner` field + `Tools/<tool>.banner.ps1`). A part script, dot-sourced inside the core, returns an object of scriptblocks: `Style` (colors), `Work` (background jobs to start) and `Complete` (turns job results into body lines and placeholder fills). The core (`Private/DFBanner.ps1`) runs all work in one runspace pool alongside tool activation, fills `@DF:<name>@` placeholder lines in the body, falls back to cached fills, and prints. Rendering helpers are pure functions.

**Tech Stack:** PowerShell 7.2+, Pester 6, fastfetch 2.69, smartctl 7.5.

**Spec:** `docs/superpowers/specs/2026-10-11-startup-banner-design.md`

## Global Constraints

- Core never names a tool: every tool-specific line lives in `Tools/<tool>.json` / `Tools/<tool>.banner.ps1`.
- Settings: `ShowBanner` (`$false`), `BannerLineDelay` (`8` ms), `BannerWait` (`300` ms), `BannerClear` (`$true`); all in `$script:DFConfigKeys`; read only through `Get-DFConfig`.
- Shown only in an interactive console host (`Test-DFInteractiveHost`) whose output isn't redirected.
- The banner never throws out of `Start-DFSession`; a failing part warns once and is left out.
- Never waits on the network beyond `BannerWait`; the public IP lookup has `-TimeoutSec 2` inside its own background job.
- Placeholder syntax `@DF:<name>@`; a placeholder with no value removes its line; `@DF:` text never reaches the screen.
- Colors and separator come from the fastfetch config in use; failing drive lines use `#f38ba8`.
- Cache: `$XDG_CACHE_HOME\dotforge\banner.json`, written with `Write-DFFileAtomic`.
- Startup cost when `ShowBanner` is off: none (one `Get-DFConfig` read).
- Tests run no real fastfetch, smartctl or network; recorded outputs live in `tests/fixtures/banner/`.
- Usual repo rules: `ConvertTo-DFPath`, `New-DFDirectory`, full comment-based help on public/companion globals, rebuild bundle/registry/reference, `Set-DFTestXdg` in tests.

## Review Focus

1. A part's `Complete` throws or returns garbage: the banner still prints the rest (Task 3 test).
2. A placeholder whose fill is a multi-line value sits in the middle of the body: the lines after it keep their order (Task 1 test).
3. fastfetch's config has comments or numeric/named colors (`"35"`, `"blue"`): colors still resolve or fall back to none, never throw (Task 1 test).
4. `Start-DFSession` called twice in one shell: the second call prints no second banner (Task 3 test).
5. A drive whose smartctl JSON lacks the fields we read (USB bridge, unsupported device): that drive is left out, others shown (Task 5 test).

---

### Task 1: Rendering helpers (pure)

**Files:**
- Create: `Private/DFBanner.Render.ps1`
- Test: `tests/Banner.Render.Tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertTo-DFAnsiColor -Color <string>` → escape prefix string (`"#rrggbb"` → `ESC[38;2;r;g;bm`; `"35"` or `"1;35"` → `ESC[35m`; anything else → `''`).
  - `New-DFBannerStyle [-KeyColor] [-OutputColor] [-Separator]` → `[pscustomobject]@{ Key; Output; Separator; Alert }` (Key/Output/Alert are escape prefixes; Alert = `#f38ba8`; Separator default `'  '`).
  - `Format-DFBannerLine -Key -Value -Style [-Alert]` → string `<key-color>Key<reset><sep><out-or-alert-color>Value<reset>` (no color codes when the color is `''`).
  - `Merge-DFBannerBody -Body [string[]] -Fills [hashtable] -Style` → `[string[]]`: every body line containing `@DF:<name>@` is replaced by the fill's lines; a fill item is `[pscustomobject]@{ Key; Value; Alert }`, and a `$null` Key takes the key text of the placeholder line (ANSI stripped, text before the separator); a name with no fill removes the line.
  - `Write-DFBannerLines -Lines -DelayMs` → writes each line with `[Console]::WriteLine`, sleeping `DelayMs` between lines (none when 0).

- [ ] **Step 1: Failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:E = [char]27
}
Describe 'Banner rendering' {
    It 'turns a hex color into a 24-bit escape' {
        ConvertTo-DFAnsiColor '#cba6f7' | Should -Be "$($script:E)[38;2;203;166;247m"
    }
    It 'passes numeric ANSI codes through and ignores names it does not know' {
        ConvertTo-DFAnsiColor '35' | Should -Be "$($script:E)[35m"
        ConvertTo-DFAnsiColor 'blue' | Should -Be ''
        ConvertTo-DFAnsiColor $null | Should -Be ''
    }
    It 'formats a line with key, separator and value colors' {
        $style = New-DFBannerStyle -KeyColor '#cba6f7' -OutputColor '#cdd6f4' -Separator '  '
        Format-DFBannerLine -Key 'Disk' -Value 'ok' -Style $style |
            Should -Be "$($script:E)[38;2;203;166;247mDisk$($script:E)[0m  $($script:E)[38;2;205;214;244mok$($script:E)[0m"
    }
    It 'uses the alert color for an alert line' {
        $style = New-DFBannerStyle -KeyColor '' -OutputColor ''
        Format-DFBannerLine -Key 'Disk' -Value 'FAIL' -Style $style -Alert | Should -Match ([regex]::Escape("$($script:E)[38;2;243;139;168mFAIL"))
    }
    It 'replaces a placeholder line with several lines, in order, keeping the lines around it' {
        $style = New-DFBannerStyle
        $body = 'A  1', 'Disk  @DF:drives@', 'B  2'
        $fills = @{ drives = @([pscustomobject]@{ Key = 'Disk x'; Value = 'ok'; Alert = $false }, [pscustomobject]@{ Key = 'Disk y'; Value = 'ok'; Alert = $false }) }
        Merge-DFBannerBody -Body $body -Fills $fills -Style $style | Should -Be @('A  1', 'Disk x  ok', 'Disk y  ok', 'B  2')
    }
    It 'takes the key from the placeholder line when the fill has none' {
        $style = New-DFBannerStyle
        $body = "$($script:E)[38;2;1;2;3mPublic IP$($script:E)[0m  $($script:E)[38;2;4;5;6m@DF:publicip@$($script:E)[0m"
        $fills = @{ publicip = @([pscustomobject]@{ Key = $null; Value = '1.2.3.4'; Alert = $false }) }
        Merge-DFBannerBody -Body $body -Fills $fills -Style $style | Should -Be 'Public IP  1.2.3.4'
    }
    It 'removes a placeholder line with no fill' {
        Merge-DFBannerBody -Body 'A', 'X  @DF:none@', 'B' -Fills @{} -Style (New-DFBannerStyle) | Should -Be @('A', 'B')
    }
    It 'writes every line, with no delay when the delay is 0' {
        Mock Start-Sleep { }
        $out = [System.IO.StringWriter]::new(); $old = [Console]::Out; [Console]::SetOut($out)
        try { Write-DFBannerLines -Lines 'a', 'b' -DelayMs 0 } finally { [Console]::SetOut($old) }
        $out.ToString() -split "`r?`n" | Where-Object { $_ } | Should -Be @('a', 'b')
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}
```

- [ ] **Step 2: Run, expect FAIL** (commands not found). `pwsh -NoProfile -Command "./build/Test-DFFull.ps1 -Path tests/Banner.Render.Tests.ps1"`

- [ ] **Step 3: Implement `Private/DFBanner.Render.ps1`**

```powershell
#Requires -Version 7.2

# Pure rendering for the startup banner (Private/DFBanner.ps1).
# See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

function ConvertTo-DFAnsiColor {
    <#
    .SYNOPSIS
        A fastfetch color (#rrggbb, or ANSI codes like "35") as an escape prefix; '' for anything else.
    .PARAMETER Color
        The color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Color)
    $e = [char]27
    if ($Color -match '^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        return "$e[38;2;$([Convert]::ToInt32($Matches[1], 16));$([Convert]::ToInt32($Matches[2], 16));$([Convert]::ToInt32($Matches[3], 16))m"
    }
    if ($Color -match '^\d+(;\d+)*$') { return "$e[${Color}m" }
    ''
}

function New-DFBannerStyle {
    <#
    .SYNOPSIS
        The banner's colors and separator, as escape prefixes.
    .PARAMETER KeyColor
        Key color (fastfetch display.color.keys).
    .PARAMETER OutputColor
        Value color (display.color.output).
    .PARAMETER Separator
        Text between key and value (display.separator).
    .OUTPUTS
        pscustomobject: Key, Output, Alert, Separator.
    #>
    [CmdletBinding()]
    param([string]$KeyColor, [string]$OutputColor, [string]$Separator = '  ')
    [pscustomobject]@{
        Key       = ConvertTo-DFAnsiColor $KeyColor
        Output    = ConvertTo-DFAnsiColor $OutputColor
        Alert     = ConvertTo-DFAnsiColor '#f38ba8'
        Separator = $Separator
    }
}

function Format-DFBannerLine {
    <#
    .SYNOPSIS
        One banner line: colored key, separator, colored value.
    .PARAMETER Key
        The key.
    .PARAMETER Value
        The value.
    .PARAMETER Style
        New-DFBannerStyle result.
    .PARAMETER Alert
        Color the value with the alert color.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Key, [string]$Value, [Parameter(Mandatory)]$Style, [switch]$Alert)
    $reset = "$([char]27)[0m"
    $paint = { param($prefix, $text) if ($prefix) { "$prefix$text$reset" } else { $text } }
    $valueColor = if ($Alert) { $Style.Alert } else { $Style.Output }
    "$(& $paint $Style.Key $Key)$($Style.Separator)$(& $paint $valueColor $Value)"
}

function Merge-DFBannerBody {
    <#
    .SYNOPSIS
        Replaces each @DF:<name>@ placeholder line in the body with that name's fill lines, or removes it.
    .PARAMETER Body
        The body lines (fastfetch's output).
    .PARAMETER Fills
        Name -> fill items (Key, Value, Alert). A $null Key takes the placeholder line's own key.
    .PARAMETER Style
        New-DFBannerStyle result.
    .OUTPUTS
        System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Body, [Parameter(Mandatory)][hashtable]$Fills, [Parameter(Mandatory)]$Style)
    $ansi = "$([char]27)\[[0-9;]*m"
    foreach ($line in $Body) {
        if ($line -notmatch '@DF:([\w-]+)@') { $line; continue }
        $name = $Matches[1]
        if (-not $Fills.ContainsKey($name)) { continue }
        $plain = $line -replace $ansi, ''
        $sepAt = $plain.IndexOf($Style.Separator)
        $ownKey = if ($sepAt -gt 0) { $plain.Substring(0, $sepAt) } else { '' }
        foreach ($item in @($Fills[$name])) {
            $key = if ($null -ne $item.Key) { $item.Key } else { $ownKey }
            Format-DFBannerLine -Key $key -Value $item.Value -Style $Style -Alert:([bool]$item.Alert)
        }
    }
}

function Write-DFBannerLines {
    <#
    .SYNOPSIS
        Prints banner lines one at a time, like a printer.
    .PARAMETER Lines
        The lines.
    .PARAMETER DelayMs
        Pause between lines; 0 prints at once.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Lines, [int]$DelayMs)
    $first = $true
    foreach ($line in $Lines) {
        if (-not $first -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        [Console]::WriteLine($line)
        $first = $false
    }
}
```

(The placeholder-key test expects no color codes because the test style has none; real styles add them.)

- [ ] **Step 4: Run, expect PASS.**

---

### Task 2: Background work in a runspace pool

**Files:**
- Create: `Private/DFBanner.Work.ps1`
- Test: `tests/Banner.Work.Tests.ps1`

**Interfaces:**
- Produces:
  - `Start-DFBannerWork -Work [object[]]` (each `@{ Name; ScriptBlock; ArgumentList }`) → handle `[pscustomobject]@{ Pool; Jobs = [list of @{ Name; PowerShell; Async }] }`.
  - `Receive-DFBannerWork -Handle -WaitMs` → `[hashtable]` name → output (object[]) for jobs finished within the wait; jobs that threw are left out with `Write-Verbose`. Disposes everything, stopping unfinished jobs without waiting for them.

- [ ] **Step 1: Failing tests**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
}
Describe 'Banner background work' {
    It 'runs jobs in parallel and returns each finished result by name' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $h = Start-DFBannerWork -Work @(
            @{ Name = 'a'; ScriptBlock = { param($x) Start-Sleep -Milliseconds 200; "a$x" }; ArgumentList = @(1) }
            @{ Name = 'b'; ScriptBlock = { Start-Sleep -Milliseconds 200; 'b' }; ArgumentList = @() })
        $r = Receive-DFBannerWork -Handle $h -WaitMs 2000
        $sw.ElapsedMilliseconds | Should -BeLessThan 380
        $r['a'] | Should -Be 'a1'
        $r['b'] | Should -Be 'b'
    }
    It 'leaves out a job that is not done within the wait, without waiting for it' {
        $h = Start-DFBannerWork -Work @(@{ Name = 'slow'; ScriptBlock = { Start-Sleep -Seconds 5; 'x' }; ArgumentList = @() })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Receive-DFBannerWork -Handle $h -WaitMs 100
        $sw.ElapsedMilliseconds | Should -BeLessThan 1000
        $r.ContainsKey('slow') | Should -BeFalse
    }
    It 'leaves out a job that throws' {
        $h = Start-DFBannerWork -Work @(@{ Name = 'bad'; ScriptBlock = { throw 'boom' }; ArgumentList = @() })
        (Receive-DFBannerWork -Handle $h -WaitMs 2000).ContainsKey('bad') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

```powershell
#Requires -Version 7.2

function Start-DFBannerWork {
    <#
    .SYNOPSIS
        Starts the banner parts' background jobs in one runspace pool, so they run while tools load.
    .PARAMETER Work
        Items with Name, ScriptBlock and ArgumentList.
    .OUTPUTS
        A handle for Receive-DFBannerWork.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Work)
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, @($Work).Count))
    $pool.Open()
    $jobs = foreach ($item in $Work) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($item.ScriptBlock.ToString())
        foreach ($arg in @($item.ArgumentList)) { $null = $ps.AddArgument($arg) }
        [pscustomobject]@{ Name = $item.Name; PowerShell = $ps; Async = $ps.BeginInvoke() }
    }
    [pscustomobject]@{ Pool = $pool; Jobs = @($jobs) }
}

function Receive-DFBannerWork {
    <#
    .SYNOPSIS
        Collects the background jobs that finish within WaitMs; stops and disposes the rest.
    .PARAMETER Handle
        Start-DFBannerWork result.
    .PARAMETER WaitMs
        Longest total wait.
    .OUTPUTS
        System.Collections.Hashtable: name -> output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Handle, [int]$WaitMs)
    $results = @{}
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    foreach ($job in $Handle.Jobs) {
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($job.Async.AsyncWaitHandle.WaitOne($left)) {
            try {
                $output = $job.PowerShell.EndInvoke($job.Async)
                if (-not $job.PowerShell.HadErrors) { $results[$job.Name] = @($output) }
                else { Write-Verbose "DotForge: banner job $($job.Name) failed: $($job.PowerShell.Streams.Error | Select-Object -First 1)" }
            } catch { Write-Verbose "DotForge: banner job $($job.Name) failed: $($_.Exception.Message)" }
        }
        $null = $job.PowerShell.BeginStop($null, $null)
        $job.PowerShell.Dispose()
    }
    $Handle.Pool.BeginClose($null, $null) | Out-Null
    $results
}
```

(Unfinished jobs are stopped asynchronously and their pool closed asynchronously, so collecting never waits on them. Check that `BeginClose` doesn't block; if it does, call `Dispose()` on a `[System.Threading.Tasks.Task]::Run`.)

- [ ] **Step 4: Run, expect PASS.**

---

### Task 3: The coordinator, settings, schema, and `Start-DFSession`

**Files:**
- Create: `Private/DFBanner.ps1`
- Modify: `Private/DFSessionConfig.ps1` (four keys), `Shared/Test-DFToolSchema.ps1` (`banner` field), `Shared/Import-DFToolDb.ps1` (normalize `banner`), `Public/Start-DFSession.ps1` (calls + help)
- Test: `tests/Banner.Tests.ps1`

**Interfaces:**
- Consumes: Tasks 1–2; `Test-DFInteractiveHost`, `Test-DFToolAvailable`, `Get-DFToolFolder`, `Import-DFToolDb`, `Get-DFXdgPath`, `Write-DFFileAtomic`.
- Produces:
  - Record field `banner`: `$null` or `{ script: string, body: bool, fills: string[] }`.
  - Part script contract: `Tools/<tool>.banner.ps1`, dot-sourced in a core function, outputs one object `[pscustomobject]@{ Style = { param($Context) ... } (optional); Work = { param($Context) ... }; Complete = { param($Results, $Context) ... } }`. `$Context = [pscustomobject]@{ Tool = <record> }`. `Style` returns `New-DFBannerStyle` input values `@{ KeyColor; OutputColor; Separator }`. `Work` returns work items (Task 2). `Complete` returns `[pscustomobject]@{ Body = [string[]] or $null; Fills = @{ name = fill items } }`; it receives only finished results.
  - `Start-DFBanner -Tools [string[]]` → state or `$null` (when off or not interactive). `Show-DFBanner -State` → prints.
  - `Get-DFBannerCachePath` → `$XDG_CACHE_HOME\dotforge\banner.json`; cache content `{ "<fill name>": { "at": "<iso>", "items": [ {Key, Value, Alert} ] } }`.

- [ ] **Step 1: Failing tests** (fake part scripts in a user tools folder; `Test-DFInteractiveHost` mocked `$true`; `[Console]::IsOutputRedirected` is behind `Test-DFBannerHost`, which tests mock)

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    function Write-Part([string]$Name, [string]$Banner, [string]$Script) {
        @{ name = $Name; executable = 'Pester'; type = 'module'; banner = ($Banner | ConvertFrom-Json) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:User "$Name.json")
        Set-Content (Join-Path $script:User "$Name.banner.ps1") $Script
    }
    function Get-Printed { $script:Printed }
}
Describe 'Startup banner' {
    BeforeEach {
        Set-DFTestXdg; Reset-DFTestSession
        $script:DFToolDb = $null; $script:DFToolRecordCache = @{}
        $script:User = Join-Path $Env:XDG_CONFIG_HOME 'dotforge' 'tools'
        Remove-Item (Join-Path $TestDrive 'xdg') -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Force $script:User | Out-Null
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0; BannerWait = 200; BannerClear = $false }
        Mock Test-DFBannerHost { $true }
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-DFBannerLines { foreach ($l in $Lines) { $script:Printed.Add(($l -replace "$([char]27)\[[0-9;]*m", '')) } }
        Mock Clear-Host { }
        Write-Part body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Style = { param($Context) @{ KeyColor = ''; OutputColor = ''; Separator = '  ' } }
    Work = { param($Context) @(@{ Name = 'ip'; ScriptBlock = { '9.9.9.9' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context)
        [pscustomobject]@{ Body = @('OS  Win', 'Public IP  @DF:ip@', 'Disk  @DF:drives@')
            Fills = @{ ip = @(if ($Results['ip']) { [pscustomobject]@{ Key = $null; Value = "$($Results['ip'])"; Alert = $false } }) } } }
}
'@
        Write-Part drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' @'
[pscustomobject]@{
    Work = { param($Context) @(@{ Name = 'drives'; ScriptBlock = { 'x' }; ArgumentList = @() }) }
    Complete = { param($Results, $Context)
        [pscustomobject]@{ Body = $null; Fills = @{ drives = @([pscustomobject]@{ Key = 'Disk A'; Value = 'ok'; Alert = $false }) } } }
}
'@
    }
    AfterEach { Set-DFTestConfig $null; $script:DFToolDb = $null; $script:DFToolRecordCache = @{}; Restore-DFTestXdg }

    It 'prints the first line at once, then the body with placeholders filled' {
        $state = Start-DFBanner -Tools body, drives
        (Get-Printed)[0] | Should -Match '^DotForge .* loading 2 tools'
        Show-DFBanner -State $state
        @(Get-Printed)[1..3] | Should -Be @('OS  Win', 'Public IP  9.9.9.9', 'Disk A  ok')
    }
    It 'prints nothing and starts nothing when ShowBanner is off' {
        Set-DFTestConfig @{ ShowBanner = $false }
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
        Get-Printed | Should -BeNullOrEmpty
    }
    It 'prints nothing in a non-interactive host' {
        Mock Test-DFBannerHost { $false }
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
    }
    It 'clears the screen first unless BannerClear is false' {
        Set-DFTestConfig @{ ShowBanner = $true; BannerLineDelay = 0; BannerClear = $true }
        $null = Start-DFBanner -Tools body
        Should -Invoke Clear-Host -Times 1 -Exactly
    }
    It 'uses a cached fill, marked, when its job is not back in time, and removes a line with no fill at all' {
        Write-DFFileAtomic -Path (Get-DFBannerCachePath) -Value '{ "ip": { "at": "2026-10-11T00:00:00Z", "items": [ { "Key": null, "Value": "1.1.1.1", "Alert": false } ] } }'
        Write-Part body '{ "script": "body.banner.ps1", "body": true, "fills": ["ip"] }' @'
[pscustomobject]@{
    Work = { param($Context) @(@{ Name = 'ip'; ScriptBlock = { Start-Sleep -Seconds 5 }; ArgumentList = @() }) }
    Complete = { param($Results, $Context) [pscustomobject]@{ Body = @('Public IP  @DF:ip@', 'Disk  @DF:drives@'); Fills = @{} } }
}
'@
        Show-DFBanner -State (Start-DFBanner -Tools body)
        @(Get-Printed)[1..2] | Should -Be @('Public IP  1.1.1.1 (cached)')
    }
    It 'caches fills for the next shell' {
        Show-DFBanner -State (Start-DFBanner -Tools body, drives)
        (Get-Content (Get-DFBannerCachePath) -Raw | ConvertFrom-Json).ip.items[0].Value | Should -Be '9.9.9.9'
    }
    It 'still prints the rest when a part throws, with one warning' {
        Write-Part drives '{ "script": "drives.banner.ps1", "fills": ["drives"] }' '[pscustomobject]@{ Work = { @() }; Complete = { throw "bad" } }'
        Show-DFBanner -State (Start-DFBanner -Tools body, drives) -WarningVariable w 3>$null
        @(Get-Printed) | Should -Contain 'OS  Win'
        @($w).Count | Should -Be 1
    }
    It 'shows only the first line with no body part' {
        Show-DFBanner -State (Start-DFBanner -Tools drives)
        @(Get-Printed).Count | Should -Be 1
    }
    It 'shows the banner once per shell' {
        Show-DFBanner -State (Start-DFBanner -Tools body)
        Start-DFBanner -Tools body | Should -BeNullOrEmpty
    }
    It 'Start-DFSession shows it around tool activation' {
        Set-DFTestConfig $null
        Mock Start-DFBanner { 'state' }
        Mock Show-DFBanner { }
        Start-DFSession -Config @{ Tools = @(); ShowBanner = $true } 3>$null
        Should -Invoke Start-DFBanner -Times 1 -Exactly
        Should -Invoke Show-DFBanner -Times 1 -Exactly -ParameterFilter { $State -eq 'state' }
    }
}
```

(`Reset-DFTestSession` must also clear the once-per-shell flag `$script:DFBannerShown`; add that to it in `tests/TestSupport.ps1`.)

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

Settings in `$script:DFConfigKeys`:

```powershell
    ShowBanner         = 'Show the startup banner (fastfetch, drive health, public IP)'
    BannerLineDelay    = 'Milliseconds between banner lines; 0 prints at once'
    BannerWait         = 'Longest wait, in ms, for an unfinished banner part'
    BannerClear        = 'Clear the screen before the banner; $false keeps scrollback'
```

Normalize in `ConvertTo-DFToolRecord` (`banner = ConvertTo-DFBannerField (Get-DFToolRecordProperty $Tool 'banner' $null)`): `$null`, or `{ script; body = [bool]; fills = [string[]] }`. Schema (`Get-DFBannerSchemaError`, called from `Test-DFToolSchema`): `banner` must be an object; `script` a non-empty string ending `.banner.ps1`; `body` a boolean if present; `fills` an array of `^[\w-]+$` strings. Add `banner` to the top-level known fields and `banner = 'script','body','fills'` to the typo table.

`Private/DFBanner.ps1`:

```powershell
#Requires -Version 7.2

# The startup banner's coordinator. Core never names a tool: parts come from
# records with a banner field. See docs/superpowers/specs/2026-10-11-startup-banner-design.md.

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
        The banner's cache of last known fills: $XDG_CACHE_HOME\dotforge\banner.json.
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
        Parts come from the requested, installed tools whose records have a
        banner field. Returns the state Show-DFBanner needs, or $null when the
        banner is off, the host isn't interactive, or it was already shown in
        this shell. Never throws.
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
        $styleValues = foreach ($part in $parts) { if ($part.Script.Style) { & $part.Script.Style $part.Context; break } }
        $style = if ($styleValues) { New-DFBannerStyle @styleValues } else { New-DFBannerStyle }
        $version = $ExecutionContext.SessionState.Module.Version
        Write-DFBannerLines -Lines @(Format-DFBannerLine -Key 'DotForge' -Value "$version · loading $(@($Tools).Count) tools…" -Style $style) -DelayMs 0
        $work = @(foreach ($part in $parts) {
            try { & $part.Script.Work $part.Context } catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed to start: $($_.Exception.Message)" }
        })
        [pscustomobject]@{ Parts = $parts; Style = $style; Handle = (Start-DFBannerWork -Work $work) }
    } catch {
        Write-Warning "DotForge: the banner failed to start: $($_.Exception.Message)"
    }
}

function Get-DFBannerPart {
    <#
    .SYNOPSIS
        Loads the banner parts of the requested, installed tools with a banner field.
    .PARAMETER Tools
        The requested tool names.
    .OUTPUTS
        pscustomobject per part: Tool, Context, Script (Style, Work, Complete).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Tools)
    if (-not $Tools) { return }
    $db = Import-DFToolDb -Name $Tools 3>$null
    foreach ($tool in @($db.Values | Where-Object { $_.banner } | Sort-Object { -not $_.banner.body }, name)) {
        if (-not (Test-DFToolAvailable -Executable $tool.executable -Type $tool.type)) { continue }
        $path = Join-Path (Get-DFToolFolder -Tool $tool -Default (ConvertTo-DFPath (Join-Path $PSScriptRoot '..' 'Tools'))) $tool.banner.script
        try {
            $script = . $path
            [pscustomobject]@{ Tool = $tool; Context = [pscustomobject]@{ Tool = $tool }; Script = $script }
        } catch { Write-Warning "DotForge: banner part $($tool.name) didn't load: $($_.Exception.Message)" }
    }
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
                foreach ($name in @($done.Fills.Keys)) { if (@($done.Fills[$name])) { $fills[$name] = @($done.Fills[$name]) } }
            } catch { Write-Warning "DotForge: banner part $($part.Tool.name) failed: $($_.Exception.Message)" }
        }
        $fills = Merge-DFBannerCache -Fills $fills -Names @($State.Parts.Tool.banner.fills)
        if ($body) { Write-DFBannerLines -Lines @(Merge-DFBannerBody -Body $body -Fills $fills -Style $State.Style) -DelayMs (Get-DFConfig BannerLineDelay -Default 8) }
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
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Fills, [AllowEmptyCollection()][string[]]$Names)
    $path = Get-DFBannerCachePath
    $cache = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $cache = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $cache = @{} }
    }
    foreach ($name in $Fills.Keys) { $cache[$name] = @{ at = [DateTime]::UtcNow.ToString('o'); items = @($Fills[$name]) } }
    $all = @{}
    foreach ($name in $Fills.Keys) { $all[$name] = $Fills[$name] }
    foreach ($name in $Names) {
        if ($all.ContainsKey($name) -or -not $cache.ContainsKey($name)) { continue }
        $all[$name] = @(foreach ($item in $cache[$name].items) {
            [pscustomobject]@{ Key = $item.Key; Value = "$($item.Value) (cached)"; Alert = [bool]$item.Alert }
        })
    }
    if ($Fills.Count) { Write-DFFileAtomic -Path $path -Value ($cache | ConvertTo-Json -Depth 6) }
    $all
}
```

In `Public/Start-DFSession.ps1`, after `$request` is computed:

```powershell
    $banner = Start-DFBanner -Tools @($request | Where-Object { -not $_.Excluded } | ForEach-Object Name)
```

and before `Write-DFConflictNotice` (so warnings print under the banner):

```powershell
    Show-DFBanner -State $banner
```

Help: `.DESCRIPTION` gains a paragraph on `ShowBanner`.

- [ ] **Step 4: Run, expect PASS**; plus `tests/DFSessionConfig.Tests.ps1`, `tests/Test-DFToolSchema.Tests.ps1`, `tests/Start-DFSession*.Tests.ps1`, `tests/ToolRegistry.Tests.ps1`. Rebuild bundle and registry.

- [ ] **Step 5: Commit** (Tasks 1–3).

---

### Task 4: The fastfetch part

**Files:**
- Create: `Tools/fastfetch.banner.ps1`, `tests/fixtures/banner/fastfetch.txt` (recorded `fastfetch --config <seeded config> --pipe false` output, with the two placeholder lines)
- Modify: `Tools/fastfetch.json` (`"banner": { "script": "fastfetch.banner.ps1", "body": true, "fills": ["publicip"] }`), `Tools/fastfetch/config.jsonc` (drop `packages` and `physicaldisk`; add the two `custom` placeholder modules), `Tools/fastfetch.ps1` (the wrapper fills placeholders from the cache)
- Test: `tests/fastfetch.Banner.Tests.ps1`

**Interfaces:**
- Consumes: the part contract (Task 3); `Merge-DFBannerBody`, `New-DFBannerStyle`, `Get-DFBannerCachePath` (Tasks 1, 3).
- Produces: fill `publicip` (one item, `Key = $null`).

Seeded config modules:

```jsonc
    "os", "host", "kernel", "uptime", "shell", "terminal",
    "cpu", "gpu", { "type": "memory", "format": "{used} / {total} ({percentage})" },
    "display", { "type": "localip", "format": "{ipv4} ({ifname})" },
    { "type": "custom", "key": "Public IP", "format": "@DF:publicip@" },
    { "type": "disk", "format": "{mountpoint} ({filesystem}): {size-used} / {size-total} ({size-percentage})" },
    { "type": "custom", "key": "Disk", "format": "@DF:drives@" }
```

`Tools/fastfetch.banner.ps1`:

```powershell
# Banner part for fastfetch: the banner's body, its colors, and the public IP.
# Dot-sourced by Private/DFBanner.ps1; outputs the part object.

$_ffSeeded = Join-Path $PSScriptRoot 'fastfetch' 'config.jsonc'   # captured now: $PSScriptRoot isn't this file inside a closure
$_ffConfigPath = {
    param($Tool)
    $raw = $Tool.settings.PSObject.Properties['configPath']?.Value ?? '${XDG_CONFIG_HOME}/fastfetch/config.jsonc'
    ConvertTo-DFPath (Expand-DFXdgPath $raw)
}
[pscustomobject]@{
    Style = {
        param($Context)
        $path = & $_ffConfigPath $Context.Tool
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = $_ffSeeded }
        try {
            $display = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop).display
            @{ KeyColor = "$($display.color.keys)"; OutputColor = "$($display.color.output)"; Separator = ($display.separator ?? '  ') }
        } catch { @{} }
    }.GetNewClosure()
    Work = {
        param($Context)
        $path = & $_ffConfigPath $Context.Tool
        $configArgs = if (Test-Path -LiteralPath $path -PathType Leaf) { @('--config', $path) } else { @() }
        @(
            @{ Name = 'fastfetch'; ScriptBlock = { param($a) & fastfetch.exe @a --pipe false 2>$null }; ArgumentList = @(, $configArgs) }
            @{ Name = 'publicip'; ScriptBlock = { (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 2).ToString().Trim() }; ArgumentList = @() }
        )
    }.GetNewClosure()
    Complete = {
        param($Results, $Context)
        $ip = "$($Results['publicip'])"
        [pscustomobject]@{
            Body  = if ($Results.ContainsKey('fastfetch')) { @($Results['fastfetch'] | ForEach-Object { "$_" }) } else { $null }
            Fills = @{ publicip = @(if ($ip -match '^[\d.:a-fA-F]+$') { [pscustomobject]@{ Key = $null; Value = $ip; Alert = $false } }) }
        }
    }
}
```

Wrapper (`Tools/fastfetch.ps1`): when the config has an `@DF:` placeholder and output isn't piped, capture `fastfetch.exe ... --pipe false`, read `banner.json` via `Get-DFBannerCachePath`, and print `Merge-DFBannerBody` with cached fills (values marked `(cached)`); otherwise unchanged. Capture `$_dfBannerCache = ${function:Get-DFBannerCachePath}` and `$_dfMerge = ${function:Merge-DFBannerBody}` closures, as the companion contract requires for private helpers.

- [ ] **Step 1: Failing tests:** `Style` reads colors from a config file under `$TestDrive` (hex, and a config with `//` comments); `Complete` with `@{ fastfetch = <fixture lines>; publicip = '1.2.3.4' }` returns the body and the fill; `Complete` with a non-IP result returns no fill; `Complete` without `fastfetch` returns `Body = $null`; the wrapper with a mocked `fastfetch.exe` (a function stub) prints no `@DF:` text.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** as above; record the fixture from the real fastfetch with the new seeded config (a one-time capture, committed).
- [ ] **Step 4: Run, expect PASS**; also `tests/fastfetch*.Tests.ps1`, `tests/ToolNative.Coverage.Tests.ps1`, registry and schema tests.

---

### Task 5: smartmontools: record, part, parser

**Files:**
- Create: `Tools/smartmontools.json`, `Tools/smartmontools.banner.ps1`, `tests/fixtures/banner/smartctl-scan.txt`, `tests/fixtures/banner/smartctl-{nvme-990,nvme-980,ssd-860,hdd-wd}.json` (recorded `smartctl -j -a -d <type> <dev>` from this machine), `tests/smartmontools.Banner.Tests.ps1`
- Modify: `data/groups.json` (`core` gains `fastfetch`, `smartmontools`)

**Interfaces:**
- Produces: fill `drives` (one item per drive, `Key = "Disk <model>"` padded to the longest key).
- Inside the part: `ConvertFrom-DFSmartctl -Json <string>` (defined in the part script, returned by its closure) → `[pscustomobject]@{ Model; Value; Alert }` or `$null`.

Record:

```json
{
  "name": "smartmontools",
  "executable": "smartctl",
  "description": "Reads drive health (SMART) for the startup banner",
  "tags": ["system", "disk"],
  "packages": { "scoop": "smartmontools", "winget": "smartmontools.smartmontools" },
  "banner": { "script": "smartmontools.banner.ps1", "fills": ["drives"] }
}
```

Part (the work runs `smartctl --scan`, then every drive's `smartctl -j -a -d <type> <dev>` at once as processes, and returns one JSON string per drive):

```powershell
# Banner part for smartmontools: one health line per drive, read without admin rights.
# Dot-sourced by Private/DFBanner.ps1; outputs the part object.

$_smartLine = {
    param([string]$Json)
    try { $d = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if (-not $d.model_name -or $null -eq $d.smart_status) { return }
    $model = ($d.model_name -replace '^(Samsung SSD|Samsung|WDC|Western Digital|Seagate|Crucial|KINGSTON|INTEL|SanDisk)\s+', '').Trim()
    $parts = [System.Collections.Generic.List[string]]::new()
    $alerts = [System.Collections.Generic.List[string]]::new()
    if (-not $d.smart_status.passed) { $alerts.Add('self-check FAILED') }
    $nvme = $d.nvme_smart_health_information_log
    $attr = @{}; foreach ($a in @($d.ata_smart_attributes.table)) { if ($a) { $attr[[int]$a.id] = $a } }
    if ($nvme) {
        $parts.Add('NVMe'); $life = 100 - [int]$nvme.percentage_used; $parts.Add("$life% life")
        if ([int]$nvme.media_errors -gt 0) { $alerts.Add("$($nvme.media_errors) media errors") }
    } elseif ($d.rotation_rate -gt 0) {
        $parts.Add('HDD'); $life = $null
    } else {
        $parts.Add('SSD')
        $wear = foreach ($id in 177, 231, 233) { if ($attr[$id]) { [int]$attr[$id].value; break } }
        $life = $wear; if ($null -ne $life) { $parts.Add("$life% life") }
    }
    $bad = foreach ($id in 5, 187, 197, 198) { if ($attr[$id] -and [long]$attr[$id].raw.value -gt 0) { "$($attr[$id].raw.value) $($attr[$id].name -replace '_', ' ')" } }
    foreach ($b in @($bad)) { $alerts.Add($b) }
    if (-not $nvme -and $d.rotation_rate -gt 0 -and -not @($bad)) { $parts.Add('no bad sectors') }
    if ($null -ne $life -and $life -lt 10) { $alerts.Add('under 10% life') }
    if ($d.temperature.current) { $parts.Add("$($d.temperature.current)°C") }
    if ($d.power_on_time.hours) { $parts.Add(('{0:N0} h' -f [long]$d.power_on_time.hours)) }
    if ($nvme.data_units_written) { $parts.Add(('{0:N0} TB written' -f ([double]$nvme.data_units_written * 512000 / 1e12))) }
    if ($alerts.Count) { $parts.Add($alerts -join ', ') }
    [pscustomobject]@{ Model = $model; Value = $parts -join ' · '; Alert = [bool]$alerts.Count }
}
[pscustomobject]@{
    Work = {
        param($Context)
        @(@{ Name = 'drives'; ScriptBlock = {
            $devices = foreach ($line in (smartctl --scan 2>$null)) { if ($line -match '^(\S+)\s+-d\s+(\S+)') { , @($Matches[1], $Matches[2]) } }
            $procs = foreach ($dev in $devices) {
                $info = [Diagnostics.ProcessStartInfo]::new('smartctl', "-j -a -d $($dev[1]) $($dev[0])")
                $info.RedirectStandardOutput = $true; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
                [Diagnostics.Process]::Start($info)
            }
            foreach ($p in $procs) { $p.StandardOutput.ReadToEnd(); $p.WaitForExit() }
        }; ArgumentList = @() })
    }
    Complete = {
        param($Results, $Context)
        $lines = @(foreach ($json in @($Results['drives'])) { & $_smartLine $json } ) | Where-Object { $_ }
        $width = ($lines | ForEach-Object { $_.Model.Length } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{ Body = $null; Fills = @{ drives = @(foreach ($l in $lines) {
            [pscustomobject]@{ Key = ('Disk ' + $l.Model.PadRight($width)); Value = $l.Value; Alert = $l.Alert } }) } }
    }.GetNewClosure()
}
```

- [ ] **Step 1: Record fixtures** from this machine (read-only):

```powershell
smartctl --scan > tests/fixtures/banner/smartctl-scan.txt
smartctl -j -a -d nvme /dev/sdd > tests/fixtures/banner/smartctl-nvme-990.json
smartctl -j -a -d nvme /dev/sdc > tests/fixtures/banner/smartctl-nvme-980.json
smartctl -j -a -d ata /dev/sda > tests/fixtures/banner/smartctl-ssd-860.json
smartctl -j -a -d ata /dev/sdb > tests/fixtures/banner/smartctl-hdd-wd.json
```

Replace each fixture's `serial_number` and `wwn` values with placeholders before committing.

- [ ] **Step 2: Failing tests:**

```powershell
BeforeAll {
    . "$PSScriptRoot/TestSupport.ps1"
    foreach ($f in Get-DFTestModuleFile) { . $f }
    $script:Part = . "$PSScriptRoot/../Tools/smartmontools.banner.ps1"
    $script:Fx = "$PSScriptRoot/fixtures/banner"
    function Get-Fill([string[]]$Files) {
        $json = foreach ($f in $Files) { Get-Content (Join-Path $script:Fx $f) -Raw }
        (& $script:Part.Complete @{ drives = @($json) } ([pscustomobject]@{})).Fills.drives
    }
}
Describe 'smartmontools banner part' {
    It 'shows NVMe life, temperature, hours and TB written' {
        (Get-Fill 'smartctl-nvme-990.json').Value | Should -Match '^NVMe · 99% life · 46°C · 14,014 h · 28 TB written$'
    }
    It 'shows a SATA SSD''s wear level as life' {
        (Get-Fill 'smartctl-ssd-860.json').Value | Should -Match '^SSD · 97% life · 38°C · 70,634 h$'
    }
    It 'shows an HDD with no bad sectors' {
        (Get-Fill 'smartctl-hdd-wd.json').Value | Should -Match '^HDD · no bad sectors · 29°C · 84,115 h$'
    }
    It 'shortens the model and pads keys to line up' {
        $keys = (Get-Fill 'smartctl-nvme-990.json', 'smartctl-hdd-wd.json').Key
        $keys[0] | Should -Be 'Disk 990 PRO 2TB  '
        $keys[0].Length | Should -Be $keys[1].Length
    }
    It 'marks a drive with reallocated sectors as an alert, with the count' {
        $j = Get-Content (Join-Path $script:Fx 'smartctl-hdd-wd.json') -Raw | ConvertFrom-Json
        ($j.ata_smart_attributes.table | Where-Object id -eq 5).raw.value = 8
        $fill = (& $script:Part.Complete @{ drives = @($j | ConvertTo-Json -Depth 20) } ([pscustomobject]@{})).Fills.drives
        $fill.Alert | Should -BeTrue
        $fill.Value | Should -Match '8 Reallocated Sector Ct'
    }
    It 'marks a failed self-check' {
        $j = Get-Content (Join-Path $script:Fx 'smartctl-nvme-980.json') -Raw | ConvertFrom-Json
        $j.smart_status.passed = $false
        (& $script:Part.Complete @{ drives = @($j | ConvertTo-Json -Depth 20) } ([pscustomobject]@{})).Fills.drives.Value | Should -Match 'self-check FAILED'
    }
    It 'leaves out a drive whose JSON lacks the fields, and keeps the others' {
        $fill = & $script:Part.Complete @{ drives = @('{ "device": {} }', (Get-Content (Join-Path $script:Fx 'smartctl-nvme-990.json') -Raw)) } ([pscustomobject]@{})
        @($fill.Fills.drives).Count | Should -Be 1
    }
    It 'returns no drive lines when the job did not finish' {
        @((& $script:Part.Complete @{} ([pscustomobject]@{})).Fills.drives).Count | Should -Be 0
    }
}
```

- [ ] **Step 3: Run, expect FAIL**, implement, **run, expect PASS**; add `smartmontools` to `+core` with `fastfetch`; rebuild registry; run `tests/Groups*.Tests.ps1`, `tests/ToolNative.Coverage.Tests.ps1`, `tests/Tools.*.Tests.ps1`.

- [ ] **Step 4: Commit** (Tasks 4–5).

---

### Task 6: Docs, reference, full run

**Files:** `docs/guide/configuration.md` ("Startup banner": the four settings, placeholders, what each line means, getting the new fastfetch default with `Invoke-DFToolSetup fastfetch -Force` or adding the placeholder lines), `docs/guide/tools.md` (smartmontools), `docs/guide/writing-a-tool.md` (the `banner` field and part contract), `CHANGELOG.md`, `docs/reference.md` (regenerated), `examples/` if a profile example shows fastfetch.

- [ ] **Step 1:** Write the docs; doc code blocks that would run fastfetch or smartctl are `<!-- system -->` or `<!-- fragment -->`.
- [ ] **Step 2:** `./build/Build-DFCoreBundle.ps1`, `./build/Build-DFToolRegistry.ps1`, `./build/Build-DFReferenceDocs.ps1`.
- [ ] **Step 3:** Full run `pwsh -NoProfile -File build/Test-DFFull.ps1`: 0 failed, 0 sentinel files.
- [ ] **Step 4:** Manual check in a real shell (dev build, `-Install` by the user): first line appears at once; banner prints a line at a time; public IP under Local IP; one line per drive; total load time no worse than today.
- [ ] **Step 5:** Commit; fast-forward `main`; push.
