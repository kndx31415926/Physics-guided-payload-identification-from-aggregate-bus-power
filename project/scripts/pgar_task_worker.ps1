[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [ValidateSet('Job', 'Sentinel')][string]$Mode = 'Job',
    [ValidateRange(10, 300)][int]$SentinelSeconds = 25
)

# This script is invoked by the Windows Task Scheduler service, never by a
# detached child process of the launching application. No recurring trigger is registered.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pgarRoot = 'C:\new'
$pgarResults = [IO.Path]::GetFullPath((Join-Path $pgarRoot 'results'))
$RunDir = [IO.Path]::GetFullPath($RunDir).TrimEnd('\')
if (-not $RunDir.StartsWith($pgarResults + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'RunDir must be a subdirectory of C:\new\results.'
}
if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
    throw 'RunDir does not exist.'
}
$pgarEncoding = New-Object System.Text.UTF8Encoding($false)
$pgarStatusPath = Join-Path $RunDir 'process_status.json'
$pgarEventsPath = Join-Path $RunDir 'process_events.jsonl'
$pgarLock = $null
$pgarKeepAwake = $false
$pgarExitCode = 0
$pgarState = $null
$pgarOriginalTemp = $env:TEMP
$pgarOriginalTmp = $env:TMP

function Write-PgarStatus {
    param([System.Collections.IDictionary]$Value)
    $Value['updated_utc'] = [DateTime]::UtcNow.ToString('o')
    $pgarTemporary = $pgarStatusPath + '.tmp.' + $PID
    [IO.File]::WriteAllText($pgarTemporary, ($Value | ConvertTo-Json -Depth 12), $pgarEncoding)
    if ([IO.File]::Exists($pgarStatusPath)) {
        # Windows PowerShell 5.1 binds a null string argument as an empty
        # path. A real backup path preserves atomic replacement there.
        [IO.File]::Replace($pgarTemporary, $pgarStatusPath, ($pgarStatusPath + '.previous'))
    } else {
        [IO.File]::Move($pgarTemporary, $pgarStatusPath)
    }
}

function Write-PgarEvent {
    param([string]$Event, [object]$Detail)
    $pgarEntry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); event = $Event; detail = $Detail }
    [IO.File]::AppendAllText($pgarEventsPath, (($pgarEntry | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), $pgarEncoding)
}

try {
    # An exclusive lock also protects against two differently registered tasks.
    try {
        $pgarLock = [IO.File]::Open((Join-Path $RunDir '.pgar_worker.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        # IgnoreNew handles normal duplicate starts. Never touch the other worker.
        exit 0
    }

    $pgarAttempt = 1
    if (Test-Path -LiteralPath $pgarStatusPath) {
        try {
            $pgarPrevious = Get-Content -LiteralPath $pgarStatusPath -Raw | ConvertFrom-Json
            if ($null -ne $pgarPrevious.PSObject.Properties['attempt']) {
                $pgarAttempt = 1 + [int]$pgarPrevious.attempt
            }
        } catch { }
    }
    $pgarSelf = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)
    $pgarAncestors = @()
    $pgarParentId = [uint32]$pgarSelf.ParentProcessId
    for ($pgarLevel = 0; $pgarLevel -lt 12 -and $pgarParentId -gt 0; $pgarLevel++) {
        $pgarParent = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $pgarParentId)
        if ($null -eq $pgarParent) { break }
        $pgarAncestors += [ordered]@{ pid = [uint32]$pgarParent.ProcessId; parent_pid = [uint32]$pgarParent.ParentProcessId; name = $pgarParent.Name; executable = $pgarParent.ExecutablePath }
        if ($pgarParentId -eq [uint32]$pgarParent.ParentProcessId) { break }
        $pgarParentId = [uint32]$pgarParent.ParentProcessId
    }
    $pgarStamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $pgarPrefix = 'attempt_{0:D3}_{1}' -f $pgarAttempt, $pgarStamp
    $pgarState = [ordered]@{
        schema = 'pgar_process_v1'; mode = $Mode; state = 'starting'; run_dir = $RunDir
        attempt = $pgarAttempt; worker_pid = $PID
        worker_created_utc = $pgarSelf.CreationDate.ToUniversalTime().ToString('o')
        worker_parent_pid = [uint32]$pgarSelf.ParentProcessId; ancestors = $pgarAncestors
        started_utc = [DateTime]::UtcNow.ToString('o'); updated_utc = $null; ended_utc = $null
        matlab_pid = $null; matlab_exit_code = $null; launcher_exit_code = $null
        stdout_log = Join-Path $RunDir ($pgarPrefix + '.stdout.log')
        stderr_log = Join-Path $RunDir ($pgarPrefix + '.stderr.log')
        matlab_log = Join-Path $RunDir ($pgarPrefix + '.matlab.log')
        prevents_automatic_sleep = $false; retryable_infrastructure_error = $false
        error = $null
        scope = 'Process status only; application checkpoints and status.json belong to run_pgar_job.'
    }
    Write-PgarStatus $pgarState
    Write-PgarEvent 'worker_started' @{ worker_pid = $PID; attempt = $pgarAttempt; mode = $Mode }

    # Process-local compiler/MATLAB scratch files stay under this run. This
    # does not alter the account's or machine's environment configuration.
    $pgarScratch = Join-Path $RunDir 'worker_temp'
    [void][IO.Directory]::CreateDirectory($pgarScratch)
    $env:TEMP = $pgarScratch
    $env:TMP = $pgarScratch
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PgarExecutionState {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
    $pgarKeepAwake = [PgarExecutionState]::SetThreadExecutionState([uint32]2147483649) -ne 0
    $pgarState['prevents_automatic_sleep'] = $pgarKeepAwake
    if (-not $pgarKeepAwake) { Write-PgarEvent 'keep_awake_unavailable' $null }
    $pgarState['state'] = 'running'
    Write-PgarStatus $pgarState

    if ($Mode -eq 'Sentinel') {
        $pgarHeartbeatPath = Join-Path $RunDir 'sentinel_heartbeat.jsonl'
        $pgarTimer = [Diagnostics.Stopwatch]::StartNew()
        $pgarBeat = 0
        while ($pgarTimer.Elapsed.TotalSeconds -lt $SentinelSeconds) {
            $pgarBeat++
            $pgarHeartbeat = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); beat = $pgarBeat; worker_pid = $PID; elapsed_s = $pgarTimer.Elapsed.TotalSeconds }
            [IO.File]::AppendAllText($pgarHeartbeatPath, (($pgarHeartbeat | ConvertTo-Json -Compress) + [Environment]::NewLine), $pgarEncoding)
            Start-Sleep -Seconds 2
        }
        $pgarState['state'] = 'completed'
        $pgarState['sentinel_heartbeats'] = $pgarBeat
    } else {
        $pgarSnapshot = Join-Path $RunDir 'source_snapshot'
        $pgarJob = Join-Path $pgarSnapshot 'run_pgar_job.m'
        $pgarMatlab = 'D:\Program Files\MATLAB\R2026a\bin\matlab.exe'
        if (-not (Test-Path -LiteralPath $pgarJob -PathType Leaf)) { throw 'Snapshot run_pgar_job.m is missing.' }
        if (-not (Test-Path -LiteralPath $pgarMatlab -PathType Leaf)) { throw 'MATLAB executable is missing.' }
        $pgarMatlabRunDir = $RunDir.Replace("'", "''")
        $pgarBatch = "run_pgar_job('$pgarMatlabRunDir')"
        # MATLAB's own -wait is required in addition to Start-Process -Wait
        # for the Windows launcher to propagate the actual batch exit code.
        $pgarArguments = '-wait -noFigureWindows -singleCompThread -sd "{0}" -batch "{1}" -logfile "{2}"' -f $pgarSnapshot, $pgarBatch, $pgarState['matlab_log']
        Write-PgarEvent 'matlab_launch_requested' @{ executable = $pgarMatlab; working_directory = $pgarSnapshot; batch = $pgarBatch }
        # Task Scheduler owns this entire process tree. -Wait keeps its worker
        # alive; Status resolves the live MATLAB child PID while this call waits.
        $pgarMatlabProcess = Start-Process -FilePath $pgarMatlab -ArgumentList $pgarArguments `
            -WorkingDirectory $pgarSnapshot -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput $pgarState['stdout_log'] -RedirectStandardError $pgarState['stderr_log']
        $pgarMatlabProcess.Refresh()
        $pgarState['matlab_pid'] = $pgarMatlabProcess.Id
        $pgarState['matlab_exit_code'] = $pgarMatlabProcess.ExitCode
        if ($pgarMatlabProcess.ExitCode -eq 0) {
            $pgarState['state'] = 'completed'
        } else {
            $pgarState['state'] = 'failed'
            $pgarState['error'] = 'MATLAB returned a nonzero exit code. Inspect MATLAB/application logs before an explicit Resume.'
            # Application failures do not trigger automatic service restarts.
            # A human can resume the exact checkpoint through the launcher.
        }
    }
} catch {
    $pgarExitCode = 1
    if ($null -ne $pgarState) {
        $pgarState['state'] = 'launcher_failed'
        $pgarState['retryable_infrastructure_error'] = $true
        $pgarState['error'] = $_.Exception.ToString()
    }
    try { Write-PgarEvent 'infrastructure_failure' $_.Exception.ToString() } catch { }
} finally {
    if ($pgarKeepAwake) { [void][PgarExecutionState]::SetThreadExecutionState([uint32]2147483648) }
    if ($null -ne $pgarState) {
        $pgarState['ended_utc'] = [DateTime]::UtcNow.ToString('o')
        $pgarState['launcher_exit_code'] = $pgarExitCode
        try { Write-PgarStatus $pgarState; Write-PgarEvent 'worker_exited' @{ state = $pgarState['state']; launcher_exit_code = $pgarExitCode; matlab_exit_code = $pgarState['matlab_exit_code'] } } catch { $pgarExitCode = 1 }
    }
    if ($null -ne $pgarLock) { $pgarLock.Dispose() }
    $env:TEMP = $pgarOriginalTemp
    $env:TMP = $pgarOriginalTmp
}
exit $pgarExitCode
