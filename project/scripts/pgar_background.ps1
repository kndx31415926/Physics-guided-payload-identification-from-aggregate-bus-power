[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [ValidateSet('Start', 'Status', 'Resume', 'Stop')][string]$Action = 'Status',
    [switch]$SmokeTest,
    [ValidateRange(10, 300)][int]$SentinelSeconds = 25
)

# A demand-only Windows scheduled task survives the launching process tree.
# Interactive-token execution needs this Windows account to remain logged in.
# Usage: .\pgar_background.ps1 -RunDir C:\new\results\<run> -Action Start
# Status is read-only. Resume reruns the frozen job, whose own checkpoints
# determine what remains. Stop targets only this task's verified process tree.
# During MATLAB's blocking wait, process_status.matlab_pid remains null;
# Status.live_processes resolves the live MATLAB launcher/worker descendants.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pgarRoot = 'C:\new'
$pgarResults = [IO.Path]::GetFullPath((Join-Path $pgarRoot 'results'))
$RunDir = [IO.Path]::GetFullPath($RunDir).TrimEnd('\')
if (-not $RunDir.StartsWith($pgarResults + '\', [StringComparison]::OrdinalIgnoreCase) -or $RunDir -match '[\r\n]') {
    throw 'RunDir must be a subdirectory of C:\new\results without newline characters.'
}
if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
    if ($SmokeTest -and $Action -eq 'Start') { [void](New-Item -ItemType Directory -Path $RunDir -Force) }
    else { throw 'Create the job RunDir and source_snapshot before Start.' }
}
$pgarHasher = [Security.Cryptography.SHA256]::Create()
try { $pgarHash = [BitConverter]::ToString($pgarHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($RunDir.ToLowerInvariant()))).Replace('-', '').Substring(0, 12) }
finally { $pgarHasher.Dispose() }
$pgarLeaf = ([IO.Path]::GetFileName($RunDir) -replace '[^a-zA-Z0-9_-]', '_')
if ($pgarLeaf.Length -gt 45) { $pgarLeaf = $pgarLeaf.Substring(0, 45) }
$pgarTaskName = 'PGAR-' + $pgarLeaf + '-' + $pgarHash
$pgarTaskPath = '\'
$pgarDescription = 'PGAR demand-only independent MATLAB worker. RunDir=' + $RunDir
$pgarLauncherPath = Join-Path $RunDir 'launcher_status.json'
$pgarProcessPath = Join-Path $RunDir 'process_status.json'
$pgarEncoding = New-Object System.Text.UTF8Encoding($false)

function Get-PgarProcessStatus {
    if (Test-Path -LiteralPath $pgarProcessPath) {
        try { return (Get-Content -LiteralPath $pgarProcessPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Get-PgarOwnedTask {
    $pgarExisting = Get-ScheduledTask -TaskName $pgarTaskName -TaskPath $pgarTaskPath -ErrorAction SilentlyContinue
    if ($null -ne $pgarExisting -and $pgarExisting.Description -ne $pgarDescription) {
        throw 'Task name is occupied by a task without the matching PGAR ownership description.'
    }
    return $pgarExisting
}

function Get-PgarWorkerTree {
    param([object]$ProcessStatus)
    if ($null -eq $ProcessStatus) { return @() }
    $pgarProcesses = @(Get-CimInstance Win32_Process)
    $pgarWorker = @($pgarProcesses | Where-Object { $_.ProcessId -eq [uint32]$ProcessStatus.worker_pid })
    if ($pgarWorker.Count -ne 1) { return @() }
    # Creation time prevents a stale PID from matching an unrelated process.
    # PowerShell 7 parses JSON timestamps as DateTime; 5.1 leaves strings.
    # Compare the UTC value, not display formatting, on both hosts.
    $pgarRecordedCreation = [datetime]$ProcessStatus.worker_created_utc
    if ($pgarWorker[0].CreationDate.ToUniversalTime().Ticks -ne $pgarRecordedCreation.ToUniversalTime().Ticks) { return @() }
    $pgarFound = @($pgarWorker[0])
    $pgarFrontier = @([uint32]$ProcessStatus.worker_pid)
    while ($pgarFrontier.Count -gt 0) {
        $pgarChildren = @($pgarProcesses | Where-Object { $pgarFrontier -contains [uint32]$_.ParentProcessId -and $_.ProcessId -ne $_.ParentProcessId })
        if ($pgarChildren.Count -eq 0) { break }
        $pgarFound += $pgarChildren
        $pgarFrontier = @($pgarChildren | ForEach-Object { [uint32]$_.ProcessId })
    }
    return $pgarFound
}

function Show-PgarStatus {
    param([string]$Message)
    $pgarTask = Get-PgarOwnedTask
    $pgarProcess = Get-PgarProcessStatus
    $pgarInfo = $null
    if ($null -ne $pgarTask) { $pgarInfo = Get-ScheduledTaskInfo -TaskName $pgarTaskName -TaskPath $pgarTaskPath }
    $pgarTree = @(Get-PgarWorkerTree $pgarProcess)
    $pgarOutput = [ordered]@{
        task_name = $pgarTaskName; task_path = $pgarTaskPath; run_dir = $RunDir; message = $Message
        scheduler_state = $(if ($null -eq $pgarTask) { 'not_registered' } else { [string]$pgarTask.State })
        last_task_result = $(if ($null -eq $pgarInfo) { $null } else { $pgarInfo.LastTaskResult })
        task_trigger_count = $(if ($null -eq $pgarTask) { 0 } else { @($pgarTask.Triggers | Where-Object { $null -ne $_ }).Count })
        live_processes = @($pgarTree | Select-Object @{n='pid';e={$_.ProcessId}}, @{n='parent_pid';e={$_.ParentProcessId}}, Name, ExecutablePath)
        process_status = $pgarProcess
        application_status_path = Join-Path $RunDir 'status.json'
        limitations = 'Closing the launching application is supported. Logging off, shutdown/reboot, forced sleep, or power loss can interrupt the job. The worker temporarily inhibits automatic sleep without changing power settings.'
    }
    $pgarOutput | ConvertTo-Json -Depth 14
}

if ($Action -eq 'Status') { Show-PgarStatus 'Read-only status.'; exit 0 }
if ((Get-Service -Name Schedule).Status -ne 'Running') { throw 'Windows Task Scheduler service is not running.' }
$pgarTask = Get-PgarOwnedTask
$pgarProcess = Get-PgarProcessStatus

if ($Action -eq 'Stop') {
    if ($null -eq $pgarTask) { throw 'This RunDir has no registered PGAR task.' }
    $pgarTree = @(Get-PgarWorkerTree $pgarProcess)
    # Only the exact owned task and its already-verified process tree are stopped.
    Stop-ScheduledTask -TaskName $pgarTaskName -TaskPath $pgarTaskPath
    for ($pgarIndex = $pgarTree.Count - 1; $pgarIndex -ge 0; $pgarIndex--) {
        $pgarOriginal = $pgarTree[$pgarIndex]
        $pgarCurrent = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $pgarOriginal.ProcessId)
        if ($null -ne $pgarCurrent -and $pgarCurrent.CreationDate -eq $pgarOriginal.CreationDate) {
            Stop-Process -Id $pgarOriginal.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    $pgarStopped = [ordered]@{ action = 'Stop'; task_name = $pgarTaskName; run_dir = $RunDir; utc = [DateTime]::UtcNow.ToString('o'); state = 'stop_requested'; note = 'Application checkpoint validity is determined by run_pgar_job on Resume.' }
    [IO.File]::WriteAllText($pgarLauncherPath, ($pgarStopped | ConvertTo-Json), $pgarEncoding)
    Show-PgarStatus 'Stopped only this scheduled task and its verified descendants. An interrupted process_status may remain running; scheduler/live process state is authoritative.'
    exit 0
}

if ($null -ne $pgarTask -and [string]$pgarTask.State -in @('Running', 'Queued')) {
    Show-PgarStatus 'Already running or queued; no second worker was launched.'; exit 0
}
if (@(Get-PgarWorkerTree $pgarProcess).Count -gt 0) {
    Show-PgarStatus 'The matching worker is still alive; no second worker was launched.'; exit 0
}
if ($Action -eq 'Start' -and $null -ne $pgarProcess -and $pgarProcess.state -eq 'completed') {
    Show-PgarStatus 'Already completed. Use Resume explicitly only if the application has additional pending work.'; exit 0
}

$pgarWorker = Join-Path $pgarRoot 'scripts\pgar_task_worker.ps1'
if (-not $SmokeTest) {
    $pgarSnapshot = Join-Path $RunDir 'source_snapshot'
    if (-not (Test-Path -LiteralPath (Join-Path $pgarSnapshot 'run_pgar_job.m') -PathType Leaf)) {
        throw 'The immutable source_snapshot must contain run_pgar_job.m before Start/Resume.'
    }
    $pgarWorker = Join-Path $pgarSnapshot 'scripts\pgar_task_worker.ps1'
    if (-not (Test-Path -LiteralPath $pgarWorker -PathType Leaf)) {
        throw 'Copy scripts/pgar_task_worker.ps1 into the source snapshot before Start/Resume.'
    }
}
if (-not (Test-Path -LiteralPath $pgarWorker -PathType Leaf)) { throw 'PGAR worker script is missing.' }
$pgarMode = $(if ($SmokeTest) { 'Sentinel' } else { 'Job' })
$pgarCommand = "& '{0}' -RunDir '{1}' -Mode '{2}' -SentinelSeconds {3}" -f $pgarWorker.Replace("'", "''"), $RunDir.Replace("'", "''"), $pgarMode, $SentinelSeconds
$pgarEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pgarCommand))
$pgarWindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pgarArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $pgarEncoded
$pgarTaskAction = New-ScheduledTaskAction -Execute $pgarWindowsPowerShell -Argument $pgarArguments -WorkingDirectory $pgarRoot
$pgarTaskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
# Match an ordinary MATLAB session. Scheduler's default priority 7 inherits
# BelowNormal and substantially slows this CPU-bound job on this workstation.
$pgarTaskSettings.Priority = 4
$pgarUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pgarPrincipal = New-ScheduledTaskPrincipal -UserId $pgarUser -LogonType Interactive -RunLevel Limited
$pgarDefinition = New-ScheduledTask -Action $pgarTaskAction -Settings $pgarTaskSettings -Principal $pgarPrincipal -Description $pgarDescription
[void](Register-ScheduledTask -TaskName $pgarTaskName -TaskPath $pgarTaskPath -InputObject $pgarDefinition -Force)
$pgarLaunch = [ordered]@{
    schema = 'pgar_launcher_v1'; action = $Action; state = 'launch_requested'; utc = [DateTime]::UtcNow.ToString('o')
    task_name = $pgarTaskName; task_path = $pgarTaskPath; run_dir = $RunDir; mode = $pgarMode; worker_script = $pgarWorker
    user = $pgarUser; logon_type = 'Interactive'; execution_time_limit = 'PT0S'; recurring = $false
    automatic_infrastructure_restarts = 2; application_failures_require_explicit_resume = $true
}
[IO.File]::WriteAllText($pgarLauncherPath, ($pgarLaunch | ConvertTo-Json -Depth 6), $pgarEncoding)
Start-ScheduledTask -TaskName $pgarTaskName -TaskPath $pgarTaskPath
Show-PgarStatus 'Task Scheduler accepted the demand start. The task runs independently of the launching application; inspect process_status and application status/logs for progress.'
