# Companion for btop (btop4win). Two builds install as btop.exe: the plain one runs
# as you; btop-lhm (LibreHardwareMonitor, for hardware sensors) needs admin rights
# and asks Windows for them itself (UAC) every run. When the lhm build is the one on
# PATH and an elevator (gsudo) is active this session, btop runs it through the
# elevator in this console, so its cached credentials spare the prompt. Otherwise
# nothing is wrapped. Reads nothing from $DFConfig; writes no files.

function Get-DFBtopBuild {
    # 'lhm' when LibreHardwareMonitorLib.dll sits beside the real exe (a scoop shim resolved),
    # 'plain' when the exe exists without it, nothing when there is no exe.
    param([string]$Executable)
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return }
    $target = Resolve-DFExecutableTarget -Path $Executable
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { return }
    if (Test-Path -LiteralPath (Join-Path (Split-Path $target) 'LibreHardwareMonitorLib.dll')) { 'lhm' } else { 'plain' }
}

$_btopExe = (Get-Command -Name 'btop' -CommandType Application -ErrorAction Ignore | Select-Object -First 1).Source
if ((Get-DFBtopBuild -Executable $_btopExe) -eq 'lhm') {
    # Only the elevators active this session (an installed but unrequested gsudo is left alone).
    $_active = @{}
    foreach ($name in @($script:DFSessionToolDb.Keys)) { if (Test-DFToolActive -Name $name) { $_active[$name] = $script:DFSessionToolDb[$name] } }
    $_elevation = Get-DFElevationMethod -ToolDb $_active
    if ($_elevation.Method -eq 'Elevator') {
        $_btopTarget = Resolve-DFExecutableTarget -Path $_btopExe
        $_elevator = $_elevation.Executable
        Set-Item -Path 'function:global:btop' -Value ({
            <#
            .SYNOPSIS
                Runs btop-lhm through your elevator (gsudo), in this console.
            .DESCRIPTION
                btop-lhm reads hardware sensors through LibreHardwareMonitor and
                needs admin rights. Running it through the elevator keeps it in
                this console and uses the elevator's cached credentials instead of
                a UAC prompt every time. Your arguments go to btop unchanged.

                Defined by DotForge's btop companion only when btop-lhm is the
                build on PATH and an elevator is active this session.
            .EXAMPLE
                btop

                Opens btop-lhm with admin rights in this console.
            .OUTPUTS
                None.
            .LINK
                https://github.com/simsrw73/DotForge/blob/main/docs/guide/tools.md
            #>
            & $_elevator $_btopTarget @args
        }.GetNewClosure())
    }
}