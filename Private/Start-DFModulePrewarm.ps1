#Requires -Version 7.0

function Start-DFModulePrewarm {
    <#
    .SYNOPSIS
        Fires a background job that imports each named module in its own
        throwaway runspace, purely to warm OS/CLR-level caches.
    .DESCRIPTION
        PowerShell-level session state -- loaded modules, defined functions,
        $global: variables -- is not shared across runspaces (confirmed
        empirically -- see docs/superpowers/specs/2026-09-05-startup-perf-audit.md
        Part 2), so the import performed here is never visible to the
        caller's session. This function's only purpose is the side effect of
        touching the module's files once before the caller's own (unchanged)
        Import-Module call reaches them -- that later, real import is then
        fast, due to already-warm OS/CLR-level caches (measured ~77%
        reduction on a representative module, reproduced 3/3).

        That isolation is at the PowerShell session-state level only.
        Start-ThreadJob runs its scriptblock on a thread inside the SAME
        process as the caller (unlike Start-Job, which is a separate
        process), so process-global .NET/CLR static state IS shared with
        the caller. A module whose import touches shared static/global .NET
        state -- not just PowerShell session state -- is not safe to point
        at this function: importing it here, concurrently with anything
        else touching that same static state, is a real (if narrow)
        concurrency risk. PSReadLine is the concrete example that prompted
        this note -- it keeps its key-handler dispatch table on a
        process-global static singleton, and PSFzf's import touches it. Any
        `Tools/<name>.json` can opt a tool's module out of prewarming
        entirely with a top-level `"prewarm": false` field (see
        `Tools/psreadline.json`, which sets it for exactly this reason);
        `Register-DFTool` excludes such tools from the module list it
        passes here.

        Nothing depends on this job succeeding, finishing before the caller
        continues, or running at all: a module that fails to import here is
        silently ignored (the caller's own real import will report any real
        failure normally), and a caller that never waits on the returned
        job simply gets today's synchronous-import cost for whichever
        modules the job didn't reach in time -- never worse than not
        calling this function at all. If Start-ThreadJob itself is
        unavailable (e.g. Microsoft.PowerShell.ThreadJob cannot be found),
        that failure is caught and this function returns $null, same as
        the empty-input case -- never worse than not calling this function
        at all.

        Assumes the named modules have no import-time side effects beyond
        session-local state (defining functions, format/type data, etc.) --
        true of Terminal-Icons/PSFzf/posh-git, this function's motivating
        callers. A module whose import writes files, calls the network, or
        otherwise mutates state outside its own session would have that
        side effect run twice (once here, discarded; once for real) if
        pointed at this function -- not a fit for that kind of module.
    .PARAMETER ModuleNames
        Module names to pre-import, e.g. @('Terminal-Icons', 'PSFzf'). May
        be empty.
    .OUTPUTS
        [System.Management.Automation.Job] the started background job, or
        $null when -ModuleNames is empty or Start-ThreadJob itself fails.
        Never call Receive-Job on it for its result -- there is nothing
        meaningful to receive, since the import happened in a runspace the
        caller can't see into. The caller should Remove-Job -Force it once
        done with its own work, whether or not the job has finished by then.
    .EXAMPLE
        Start-DFModulePrewarm -ModuleNames @('Terminal-Icons', 'PSFzf', 'posh-git')
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ModuleNames
    )

    if (-not $ModuleNames) {
        return $null
    }

    try {
        Start-ThreadJob -ScriptBlock {
            param([string[]]$Names)
            foreach ($name in $Names) {
                try { Import-Module -Name $name -ErrorAction Stop } catch { }
            }
        } -ArgumentList (, $ModuleNames)
    } catch {
        # Start-ThreadJob itself failed (e.g. Microsoft.PowerShell.ThreadJob is
        # unavailable) -- degrade silently, same shape as the empty-input
        # early return above. The caller's own real Import-Module downstream
        # is unaffected either way; see .DESCRIPTION.
        $null
    }
}
