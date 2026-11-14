[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [ValidateSet('Job', 'Sentinel')][string]$Mode = 'Job',
    [ValidateRange(10, 300)][int]$SentinelSeconds = 25
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RunDir = [IO.Path]::GetFullPath($RunDir).TrimEnd('\')
if (-not $RunDir.StartsWith('C:\new\results\', [StringComparison]::OrdinalIgnoreCase)) { throw 'RunDir must be below C:\new\results.' }
$pnnEncoding = New-Object Text.UTF8Encoding($false)
$pnnGuardLock = $null
$pnnGuardPath = Join-Path $RunDir 'pnn_guard_status.json'

function Write-PnnGuardState([string]$State, [string]$Note) {
    $pnnValue = [ordered]@{schema='pnn_guard_v1';state=$State;run_dir=$RunDir;mode=$Mode;pid=$PID;utc=[DateTime]::UtcNow.ToString('o');note=$Note}
    $pnnTemp = $pnnGuardPath + '.tmp.' + $PID
    [IO.File]::WriteAllText($pnnTemp, ($pnnValue | ConvertTo-Json), $pnnEncoding)
    if (Test-Path -LiteralPath $pnnGuardPath) { [IO.File]::Replace($pnnTemp,$pnnGuardPath,($pnnGuardPath+'.previous')) }
    else { [IO.File]::Move($pnnTemp,$pnnGuardPath) }
    [IO.File]::AppendAllText((Join-Path $RunDir 'pnn_guard_events.jsonl'), (($pnnValue | ConvertTo-Json -Compress)+[Environment]::NewLine), $pnnEncoding)
}

try {
    try { $pnnGuardLock = [IO.File]::Open((Join-Path $RunDir '.pnn_guard.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { exit 0 }
    if ((Test-Path -LiteralPath (Join-Path $RunDir 'COMPLETE.json') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $RunDir 'COMPLETE') -PathType Leaf)) {
        Write-PnnGuardState 'complete_noop' 'Application completion marker exists. No worker or MATLAB was launched.'
        exit 0
    }
    if (Test-Path -LiteralPath (Join-Path $RunDir 'pnn_paused.json')) {
        Write-PnnGuardState 'paused_noop' 'Explicit Stop remains in effect. Use Resume to clear it.'
        exit 0
    }
    $pnnPermitPath = Join-Path $RunDir 'pnn_manual_start.json'
    $pnnManual = Test-Path -LiteralPath $pnnPermitPath
    if ($pnnManual) { Remove-Item -LiteralPath $pnnPermitPath }
    $pnnPrior = $null
    $pnnProcessPath = Join-Path $RunDir 'process_status.json'
    if (Test-Path -LiteralPath $pnnProcessPath) {
        try { $pnnPrior = Get-Content -LiteralPath $pnnProcessPath -Raw | ConvertFrom-Json }
        catch { if (-not $pnnManual) { Write-PnnGuardState 'status_unreadable' 'Prior status could not be read. Explicit inspection and Resume are required.'; exit 0 } }
    }
    if ($null -ne $pnnPrior -and [string]$pnnPrior.state -eq 'completed') {
        if ($Mode -eq 'Sentinel') { Write-PnnGuardState 'complete_noop' 'Sentinel completed previously.'; exit 0 }
        if (-not $pnnManual) { Write-PnnGuardState 'missing_complete_marker' 'The previous worker exited successfully but the application COMPLETE marker is missing. Explicit inspection and Resume are required.'; exit 0 }
    }
    if (-not $pnnManual -and $null -ne $pnnPrior -and [string]$pnnPrior.state -in @('failed','launcher_failed')) {
        Write-PnnGuardState 'failure_requires_resume' 'A recorded failure is not retried at every login. Diagnose it and use explicit Resume.'
        exit 0
    }
    $pnnWorker = Join-Path $PSScriptRoot 'pgar_task_worker.ps1'
    if (-not (Test-Path -LiteralPath $pnnWorker -PathType Leaf)) { throw 'Frozen PGAR worker missing next to PNN guard.' }
    # The inherited worker supplies a second exclusive lock, PID creation time,
    # hidden MATLAB, process-local scratch, logs, -singleCompThread and keep-awake.
    Write-PnnGuardState 'worker_starting' 'Task Scheduler owns this process. Application checkpoints determine the remaining work.'
    & $pnnWorker -RunDir $RunDir -Mode $Mode -SentinelSeconds $SentinelSeconds
    $pnnWorkerExit = $LASTEXITCODE
    if ($null -eq $pnnWorkerExit) { $pnnWorkerExit = 0 }
    Write-PnnGuardState 'worker_returned' ('Worker launcher exit code: ' + $pnnWorkerExit + '. Inspect process_status.json for the MATLAB/application outcome.')
    exit $pnnWorkerExit
} catch {
    try { Write-PnnGuardState 'guard_failed' $_.Exception.ToString() } catch { }
    throw
} finally {
    if ($null -ne $pnnGuardLock) { $pnnGuardLock.Dispose() }
}
