[CmdletBinding()]
param([string]$RunDir='C:\new\results\pnn_launcher_sentinel_20261031_v3')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $RunDir) { throw 'Use a new sentinel RunDir; existing evidence is never overwritten.' }
$pnnLauncher='C:\new\scripts\pnn_background.ps1'
$pnnExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pnnChecks=New-Object Collections.Generic.List[object]
$pnnTaskName=$null
function Invoke-Pnn([string]$RequestedAction,[int]$Seconds=60) {
    $pnnOutput=& $pnnExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $pnnLauncher -RunDir $RunDir -Action $RequestedAction -SmokeTest -SentinelSeconds $Seconds
    if ($LASTEXITCODE -ne 0) { throw ('Launcher failed: '+($pnnOutput -join [Environment]::NewLine)) }
    return (($pnnOutput -join [Environment]::NewLine)|ConvertFrom-Json)
}
function Assert-Pnn([bool]$Condition,[string]$Name,[object]$Detail=$null) {
    if (-not $Condition) { throw ('FAIL: '+$Name) }
    $pnnChecks.Add([ordered]@{name=$Name;pass=$true;utc=[DateTime]::UtcNow.ToString('o');detail=$Detail})
}
function Wait-Pnn([scriptblock]$Predicate,[int]$Seconds=35) {
    $pnnTimer=[Diagnostics.Stopwatch]::StartNew()
    do { $pnnObserved=Invoke-Pnn 'Status';if (& $Predicate $pnnObserved) { return $pnnObserved };Start-Sleep -Milliseconds 400 } while ($pnnTimer.Elapsed.TotalSeconds -lt $Seconds)
    throw ('Timed out waiting for sentinel: '+($pnnObserved|ConvertTo-Json -Depth 12))
}
try {
    foreach ($pnnFile in @($pnnLauncher,'C:\new\scripts\pnn_resume_guard.ps1')) {
        $pnnTokens=$null;$pnnErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($pnnFile,[ref]$pnnTokens,[ref]$pnnErrors)
        Assert-Pnn (@($pnnErrors).Count -eq 0) ('syntax: '+$pnnFile)
    }
    $pnnInitial=Invoke-Pnn 'Start';$pnnTaskName=$pnnInitial.task_name
    $pnnRunning=Wait-Pnn {param($v) $null -ne $v.process_status -and $v.process_status.state -eq 'running' -and @($v.live_processes).Count -gt 0}
    $pnnPid=$pnnRunning.process_status.worker_pid
    Assert-Pnn ($pnnRunning.worker_lock_held -and $pnnRunning.scheduler_state -eq 'Running') 'scheduler owns a live independently locked worker' $pnnRunning.process_status.ancestors
    $pnnTask=Get-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    $pnnLogon=@($pnnTask.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'})
    Assert-Pnn ($pnnLogon.Count -eq 1 -and $pnnLogon[0].Enabled -and $pnnLogon[0].Delay -eq 'PT30S' -and [string]$pnnTask.Principal.LogonType -eq 'Interactive') 'current-user logon recovery configured without password' $pnnLogon[0].UserId
    Export-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'|Set-Content -LiteralPath (Join-Path $RunDir 'tested_task_definition.xml') -Encoding UTF8
    $pnnDuplicate=Invoke-Pnn 'Start'
    Assert-Pnn ($pnnDuplicate.process_status.worker_pid -eq $pnnPid -and $pnnDuplicate.process_status.attempt -eq 1) 'duplicate Start preserves the same PID and attempt'
    & $pnnExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RunDir 'source_snapshot\scripts\pnn_resume_guard.ps1') -RunDir $RunDir -Mode Sentinel -SentinelSeconds 10
    Assert-Pnn ($LASTEXITCODE -eq 0) 'second direct guard exits harmlessly while the lock is held'
    $pnnAfterGuard=Invoke-Pnn 'Status'
    Assert-Pnn ($pnnAfterGuard.process_status.attempt -eq 1 -and $pnnAfterGuard.process_status.worker_pid -eq $pnnPid) 'guard lock prevents a second worker'
    # Simulate interruption without the explicit Stop pause marker. This affects
    # only the exact sentinel task and is not a workstation logout or restart.
    $pnnOriginalCreation=[datetime]$pnnAfterGuard.process_status.worker_created_utc
    Stop-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    $pnnExactWorker=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pnnPid)
    if ($null -ne $pnnExactWorker -and $pnnExactWorker.CreationDate.ToUniversalTime().Ticks -eq $pnnOriginalCreation.ToUniversalTime().Ticks) { Stop-Process -Id $pnnPid -Force }
    $pnnInterrupted=Wait-Pnn {param($v) @($v.live_processes).Count -eq 0 -and -not $v.worker_lock_held -and $v.scheduler_state -ne 'Running'}
    Assert-Pnn (-not $pnnInterrupted.explicitly_paused -and $pnnInterrupted.process_status.state -eq 'running') 'abrupt interruption leaves recoverable stale running state without explicit pause'
    Start-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    $pnnAutomatic=Wait-Pnn {param($v) $v.process_status.attempt -eq 2 -and $v.process_status.state -eq 'running' -and @($v.live_processes).Count -gt 0}
    Assert-Pnn ($pnnAutomatic.process_status.worker_pid -ne $pnnPid -and -not $pnnAutomatic.explicitly_paused) 'logon action resumes interrupted work without manual permit'
    $pnnPid=$pnnAutomatic.process_status.worker_pid
    $pnnStopped=Invoke-Pnn 'Stop'
    $pnnStopped=Wait-Pnn {param($v) @($v.live_processes).Count -eq 0 -and -not $v.worker_lock_held -and $v.scheduler_state -ne 'Running'}
    Assert-Pnn $pnnStopped.explicitly_paused 'Stop kills only the owned worker and retains a pause marker'
    Start-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    $pnnPaused=Wait-Pnn {param($v) $v.scheduler_state -ne 'Running' -and $null -ne $v.guard_status -and $v.guard_status.state -eq 'paused_noop'}
    Assert-Pnn ($pnnPaused.process_status.attempt -eq 2 -and @($pnnPaused.live_processes).Count -eq 0) 'logon-equivalent scheduler invocation honors explicit Stop'
    $pnnResumed=Invoke-Pnn 'Resume' 10
    $pnnResumed=Wait-Pnn {param($v) $null -ne $v.process_status -and $v.process_status.attempt -eq 3 -and $v.process_status.state -eq 'running'}
    Assert-Pnn (-not $pnnResumed.explicitly_paused -and $pnnResumed.process_status.worker_pid -ne $pnnPid) 'Resume clears pause and records a new independent attempt'
    $pnnCompleted=Wait-Pnn {param($v) $v.scheduler_state -eq 'Ready' -and $v.process_status.state -eq 'completed' -and -not $v.worker_lock_held}
    Assert-Pnn ($pnnCompleted.process_status.launcher_exit_code -eq 0 -and $pnnCompleted.last_task_result -eq 0) 'resumed sentinel completes with scheduler exit zero'
    Start-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    $pnnNoop=Wait-Pnn {param($v) $v.scheduler_state -eq 'Ready' -and $v.guard_status.state -eq 'complete_noop'}
    Assert-Pnn ($pnnNoop.process_status.attempt -eq 3) 'completed sentinel is not rerun by the logon action'
    [IO.File]::WriteAllText((Join-Path $RunDir 'COMPLETE.json'),'{"schema":"pnn_launcher_test_only","test_complete_guard":true}',(New-Object Text.UTF8Encoding($false)))
    $pnnMarkerNoop=Invoke-Pnn 'Resume'
    Assert-Pnn ($pnnMarkerNoop.application_complete -and $pnnMarkerNoop.process_status.attempt -eq 3 -and $pnnMarkerNoop.scheduler_state -eq 'Ready') 'COMPLETE marker blocks even explicit Resume'
    foreach ($pnnShortcut in @('status.cmd','resume.cmd','stop.cmd')) { Assert-Pnn (Test-Path -LiteralPath (Join-Path $RunDir $pnnShortcut)) ('double-click helper: '+$pnnShortcut) }
    $pnnResult=[ordered]@{schema='pnn_launcher_tests_v1';pass=$true;run_dir=$RunDir;tested_utc=[DateTime]::UtcNow.ToString('o');checks=$pnnChecks;not_tested='The computer was not rebooted or logged out. The logon trigger was inspected and its identical scheduler action was manually invoked. No MATLAB training/data generation occurred.'}
    $pnnResult|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $RunDir 'test_result.json') -Encoding UTF8
    $pnnResult|ConvertTo-Json -Depth 14
} catch {
    if (Test-Path -LiteralPath $RunDir) { [ordered]@{pass=$false;checks=$pnnChecks;error=$_.Exception.ToString()}|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $RunDir 'test_failure.json') -Encoding UTF8 }
    throw
} finally {
    if ($null -ne $pnnTaskName) {
        $pnnCleanup=Get-ScheduledTask -TaskName $pnnTaskName -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -ne $pnnCleanup -and $pnnCleanup.Description -eq ('PNN checkpoint worker with current-user logon recovery. RunDir='+$RunDir)) {
            Stop-ScheduledTask -TaskName $pnnTaskName -TaskPath '\' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $pnnTaskName -TaskPath '\' -Confirm:$false
        }
    }
}
