[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunDir,
    [ValidateSet('Start','Status','Resume','Stop')][string]$Action='Status',
    [switch]$SmokeTest,
    [ValidateRange(10,300)][int]$SentinelSeconds=25
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$pnnRoot='C:\new'
$RunDir=[IO.Path]::GetFullPath($RunDir).TrimEnd('\')
if (-not $RunDir.StartsWith('C:\new\results\',[StringComparison]::OrdinalIgnoreCase) -or $RunDir -match '[\r\n"]') { throw 'RunDir must be a subdirectory of C:\new\results without quotes or newlines.' }
if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
    if ($SmokeTest -and $Action -eq 'Start') { [void][IO.Directory]::CreateDirectory($RunDir) }
    else { throw 'Prepare RunDir and immutable source_snapshot first.' }
}
$pnnHasher=[Security.Cryptography.SHA256]::Create()
try { $pnnHash=[BitConverter]::ToString($pnnHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($RunDir.ToLowerInvariant()))).Replace('-','').Substring(0,12) }
finally { $pnnHasher.Dispose() }
$pnnLeaf=([IO.Path]::GetFileName($RunDir) -replace '[^a-zA-Z0-9_-]','_')
if ($pnnLeaf.Length -gt 45) { $pnnLeaf=$pnnLeaf.Substring(0,45) }
$pnnTaskName='PNN-'+$pnnLeaf+'-'+$pnnHash
# Legacy ownership token retained for existing tasks; scheduling is demand-only.
$pnnDescription='PNN checkpoint worker with current-user logon recovery. RunDir='+$RunDir
$pnnEncoding=New-Object Text.UTF8Encoding($false)
$pnnPausePath=Join-Path $RunDir 'pnn_paused.json'
$pnnLauncherPath=Join-Path $RunDir 'pnn_launcher_status.json'
$pnnMutationLock=$null

function Read-PnnJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) { try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null } }
    return $null
}
function Write-PnnJson([string]$Path,[object]$Value) {
    $pnnTemp=$Path+'.tmp.'+$PID
    [IO.File]::WriteAllText($pnnTemp,($Value|ConvertTo-Json -Depth 10),$pnnEncoding)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($pnnTemp,$Path,($Path+'.previous')) }
    else { [IO.File]::Move($pnnTemp,$Path) }
}
function Get-PnnTask {
    $pnnTask=Get-ScheduledTask -TaskName $pnnTaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $pnnTask -and $pnnTask.Description -ne $pnnDescription) { throw 'Task-name ownership mismatch; refusing to touch the task.' }
    return $pnnTask
}
function Get-PnnTree([object]$State) {
    if ($null -eq $State -or $null -eq $State.PSObject.Properties['worker_pid'] -or $null -eq $State.PSObject.Properties['worker_created_utc']) { return @() }
    $pnnProcesses=@(Get-CimInstance Win32_Process)
    $pnnWorker=@($pnnProcesses|Where-Object { $_.ProcessId -eq [uint32]$State.worker_pid })
    if ($pnnWorker.Count -ne 1) { return @() }
    try { $pnnCreation=[datetime]$State.worker_created_utc } catch { return @() }
    if ($pnnWorker[0].CreationDate.ToUniversalTime().Ticks -ne $pnnCreation.ToUniversalTime().Ticks) { return @() }
    $pnnTree=@($pnnWorker[0]); $pnnFrontier=@($pnnWorker[0]); $pnnSeen=@([uint32]$pnnWorker[0].ProcessId)
    while ($pnnFrontier.Count -gt 0) {
        $pnnNext=@()
        foreach ($pnnParent in $pnnFrontier) {
            $pnnChildren=@($pnnProcesses|Where-Object { $_.ParentProcessId -eq $pnnParent.ProcessId -and $_.CreationDate -ge $pnnParent.CreationDate -and $pnnSeen -notcontains [uint32]$_.ProcessId })
            foreach ($pnnChild in $pnnChildren) { $pnnSeen+=[uint32]$pnnChild.ProcessId; $pnnNext+=$pnnChild }
        }
        $pnnTree+=$pnnNext; $pnnFrontier=$pnnNext
    }
    return $pnnTree
}
function Test-PnnWorkerLock {
    $pnnPath=Join-Path $RunDir '.pgar_worker.lock'
    if (-not (Test-Path -LiteralPath $pnnPath)) { return $false }
    try { $pnnProbe=[IO.File]::Open($pnnPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$pnnProbe.Dispose();return $false }
    catch [IO.IOException] { return $true }
}
function Test-PnnComplete { return ((Test-Path -LiteralPath (Join-Path $RunDir 'COMPLETE.json') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $RunDir 'COMPLETE') -PathType Leaf)) }
function Show-PnnStatus([string]$Message) {
    $pnnTask=Get-PnnTask; $pnnInfo=$null
    if ($null -ne $pnnTask) { $pnnInfo=Get-ScheduledTaskInfo -TaskName $pnnTaskName -TaskPath '\' }
    $pnnState=Read-PnnJson (Join-Path $RunDir 'process_status.json')
    $pnnTree=@(Get-PnnTree $pnnState)
    [ordered]@{
        schema='pnn_launcher_v1';task_name=$pnnTaskName;run_dir=$RunDir;message=$Message
        scheduler_state=$(if ($null -eq $pnnTask) {'not_registered'} else {[string]$pnnTask.State})
        last_task_result=$(if ($null -eq $pnnInfo) {$null} else {$pnnInfo.LastTaskResult})
        triggers=$(if ($null -eq $pnnTask) {@()} else {@($pnnTask.Triggers|Select-Object Enabled,UserId,Delay,@{n='type';e={$_.CimClass.CimClassName}})})
        live_processes=@($pnnTree|Select-Object @{n='pid';e={$_.ProcessId}},@{n='parent_pid';e={$_.ParentProcessId}},Name,ExecutablePath)
        worker_lock_held=(Test-PnnWorkerLock);application_complete=(Test-PnnComplete);explicitly_paused=(Test-Path -LiteralPath $pnnPausePath)
        process_status=$pnnState;guard_status=(Read-PnnJson (Join-Path $RunDir 'pnn_guard_status.json'));application_status=(Read-PnnJson (Join-Path $RunDir 'status.json'))
        recovery='Independent of the launching application once explicitly started. No boot, logon, timer or automatic retry trigger. After reboot, wait for the user to explicitly request Start/Resume; verify checkpoints and true live processes first.'
        resources='MATLAB starts with -singleCompThread. Application data generation must independently enforce at most six process workers, one thread each; training remains on CPU.'
    }|ConvertTo-Json -Depth 20
}

if ($Action -eq 'Status') { Show-PnnStatus 'Read-only status.';exit 0 }
if ((Get-Service Schedule).Status -ne 'Running') { throw 'Task Scheduler service is not running.' }
try {
    try { $pnnMutationLock=[IO.File]::Open((Join-Path $RunDir '.pnn_launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { throw 'Another Start/Resume/Stop is already updating this run. Retry Status shortly.' }
    $pnnTask=Get-PnnTask; $pnnState=Read-PnnJson (Join-Path $RunDir 'process_status.json')
    if ($Action -eq 'Stop') {
        if ($null -eq $pnnTask) { throw 'No owned PNN task is registered for this run.' }
        Write-PnnJson $pnnPausePath ([ordered]@{state='explicitly_paused';utc=[DateTime]::UtcNow.ToString('o');reason='Stop requested. Explicit Resume is required; automatic recovery is disabled.'})
        $pnnTree=@(Get-PnnTree $pnnState)
        Stop-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
        for ($pnnIndex=$pnnTree.Count-1;$pnnIndex -ge 0;$pnnIndex--) {
            $pnnPrior=$pnnTree[$pnnIndex];$pnnCurrent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pnnPrior.ProcessId)
            if ($null -ne $pnnCurrent -and $pnnCurrent.CreationDate -eq $pnnPrior.CreationDate) { Stop-Process -Id $pnnPrior.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        Show-PnnStatus 'Stopped this owned task and its verified descendants. Completed checkpoints remain. Explicit Resume is required.'
        exit 0
    }
    if (Test-PnnComplete) { Show-PnnStatus 'Application COMPLETE exists; no rerun was started.';exit 0 }
    if ($null -ne $pnnTask -and [string]$pnnTask.State -in @('Running','Queued')) { Show-PnnStatus 'Already running or queued; no duplicate launched.';exit 0 }
    if (@(Get-PnnTree $pnnState).Count -gt 0 -or (Test-PnnWorkerLock)) { Show-PnnStatus 'An existing matching worker or worker lock is active; no duplicate launched.';exit 0 }
    if ((Test-Path -LiteralPath $pnnPausePath) -and $Action -ne 'Resume') { Show-PnnStatus 'This run was explicitly stopped. Use Resume.';exit 0 }
    if ($Action -eq 'Start' -and $null -ne $pnnState -and [string]$pnnState.state -in @('failed','launcher_failed','completed')) { Show-PnnStatus 'A previous terminal worker state exists. Inspect logs, then use Resume if unfinished.';exit 0 }
    $pnnSnapshot=Join-Path $RunDir 'source_snapshot'
    $pnnGuard=Join-Path $pnnSnapshot 'scripts\pnn_resume_guard.ps1'
    $pnnWorker=Join-Path $pnnSnapshot 'scripts\pgar_task_worker.ps1'
    $pnnPriorLauncher=Read-PnnJson $pnnLauncherPath
    $pnnMode=$(if ($SmokeTest) {'Sentinel'} elseif ($null -ne $pnnPriorLauncher -and $pnnPriorLauncher.mode -eq 'Sentinel') {'Sentinel'} else {'Job'})
    if ($pnnMode -eq 'Sentinel') {
        [void][IO.Directory]::CreateDirectory((Join-Path $pnnSnapshot 'scripts'))
        foreach ($pnnScript in @('pnn_resume_guard.ps1','pgar_task_worker.ps1')) {
            $pnnDestination=Join-Path $pnnSnapshot ('scripts\'+$pnnScript)
            if (-not (Test-Path -LiteralPath $pnnDestination)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $pnnScript) -Destination $pnnDestination }
        }
    }
    if (-not (Test-Path -LiteralPath $pnnGuard -PathType Leaf) -or -not (Test-Path -LiteralPath $pnnWorker -PathType Leaf)) { throw 'Freeze scripts/pnn_resume_guard.ps1 and scripts/pgar_task_worker.ps1 into source_snapshot before Start.' }
    if ($pnnMode -eq 'Job' -and -not (Test-Path -LiteralPath (Join-Path $pnnSnapshot 'run_pgar_job.m') -PathType Leaf)) { throw 'Frozen source_snapshot/run_pgar_job.m is required.' }
    $pnnCommand="& '{0}' -RunDir '{1}' -Mode '{2}' -SentinelSeconds {3}" -f $pnnGuard.Replace("'","''"),$RunDir.Replace("'","''"),$pnnMode,$SentinelSeconds
    $pnnEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pnnCommand))
    $pnnExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $pnnTaskAction=New-ScheduledTaskAction -Execute $pnnExe -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand '+$pnnEncoded) -WorkingDirectory $pnnRoot
    $pnnSettings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $pnnSettings.Priority=4
    $pnnSettings.StartWhenAvailable=$false
    $pnnSettings.RestartCount=0
    $pnnSettings.WakeToRun=$false
    $pnnUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pnnPrincipal=New-ScheduledTaskPrincipal -UserId $pnnUser -LogonType Interactive -RunLevel Limited
    $pnnDefinition=New-ScheduledTask -Action $pnnTaskAction -Settings $pnnSettings -Principal $pnnPrincipal -Description $pnnDescription
    [void](Register-ScheduledTask -TaskName $pnnTaskName -TaskPath '\' -InputObject $pnnDefinition -Force)
    if ($Action -eq 'Resume' -and (Test-Path -LiteralPath $pnnPausePath)) { Remove-Item -LiteralPath $pnnPausePath }
    Write-PnnJson (Join-Path $RunDir 'pnn_manual_start.json') ([ordered]@{action=$Action;utc=[DateTime]::UtcNow.ToString('o');task_name=$pnnTaskName})
    Write-PnnJson $pnnLauncherPath ([ordered]@{schema='pnn_launcher_v1';action=$Action;utc=[DateTime]::UtcNow.ToString('o');task_name=$pnnTaskName;run_dir=$RunDir;mode=$pnnMode;user=$pnnUser;guard_script=$pnnGuard;guard_sha256=(Get-FileHash -LiteralPath $pnnGuard -Algorithm SHA256).Hash;worker_sha256=(Get-FileHash -LiteralPath $pnnWorker -Algorithm SHA256).Hash;logon_recovery=$false;logon_delay_s=0;manual_start_only=$true;password_stored=$false})
    foreach ($pnnShortcutAction in @('Status','Resume','Stop')) {
        $pnnShortcut=Join-Path $RunDir ($pnnShortcutAction.ToLowerInvariant()+'.cmd')
        $pnnContents='@echo off'+[Environment]::NewLine+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\new\scripts\pnn_background.ps1" -RunDir "'+$RunDir+'" -Action '+$pnnShortcutAction+[Environment]::NewLine+'pause'+[Environment]::NewLine
        if (-not (Test-Path -LiteralPath $pnnShortcut)) { [IO.File]::WriteAllText($pnnShortcut,$pnnContents,[Text.Encoding]::ASCII) }
    }
    Start-ScheduledTask -TaskName $pnnTaskName -TaskPath '\'
    Show-PnnStatus 'Scheduler accepted the explicit independent start. Automatic recovery is disabled; application checkpoints and true live processes determine progress.'
} finally { if ($null -ne $pnnMutationLock) { $pnnMutationLock.Dispose() } }
