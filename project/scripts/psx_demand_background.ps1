[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [ValidateSet('Status','Resume')][string]$Action='Status',
    [switch]$AuthorizeFormal
)
# A manually started Windows-owned worker. No timer, boot, logon or retry trigger.
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
if(-not $run.StartsWith('C:\new\results\',[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($run) -notmatch '^psx_[A-Za-z0-9_-]+$'){throw 'Unexpected run directory'}
$taskName='PSX-'+[IO.Path]::GetFileName($run)
$description='PSX demand-only manual worker. RunDirectory='+$run
$snapshot=Join-Path $run 'source_snapshot'
$workerScript=Join-Path $run 'launcher_snapshot\psx_worker.ps1'
$spec=Get-Content -LiteralPath (Join-Path $run 'spec.json') -Raw | ConvertFrom-Json
function Read-Json([string]$Name){$file=Join-Path $run $Name;if(Test-Path -LiteralPath $file){Get-Content -LiteralPath $file -Raw | ConvertFrom-Json}}
function Get-Task{
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task -and $task.Description -ne $description){throw 'Task ownership mismatch'}
    return $task
}
function Show-Status{
    $task=Get-Task;$taskInfo=$null;if($task){$taskInfo=Get-ScheduledTaskInfo -TaskName $taskName}
    $state=Read-Json 'worker_status.json';$application=Read-Json 'status.json';$live=$null
    if($state){
        $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$state.worker_pid)
        if($candidate -and $candidate.CommandLine -like ('*'+$workerScript+'*') -and
            $candidate.CreationDate.ToUniversalTime() -ge ([datetime]$state.started_utc).ToUniversalTime().AddSeconds(-5)){$live=$candidate}
    }
    $effective='not_started';if($state){$effective=$state.state}
    if($state -and $state.state -eq 'running' -and -not $live){$effective='interrupted_process_missing'}
    $paused=Test-Path -LiteralPath (Join-Path $run 'psx_paused.json')
    if($paused){$effective=if($live){'pausing'}else{'paused'}}
    [ordered]@{run_directory=$run;effective_state=$effective;task_name=$taskName;
        task_state=$(if($task){[string]$task.State}else{'not_registered'});
        last_task_result=$(if($taskInfo){$taskInfo.LastTaskResult}else{$null});
        live_worker_pid=$(if($live){$live.ProcessId}else{$null});application=$application;worker=$state;
        trigger_count=$(if($task){@($task.Triggers | Where-Object {$null -ne $_}).Count}else{0});
        explicitly_paused=$paused;automatic_restart=$false}|ConvertTo-Json -Depth 8
}
if($Action -eq 'Status'){Show-Status;exit 0}
if(-not $spec.smoke_test -and -not $AuthorizeFormal){throw 'Formal resume requires explicit -AuthorizeFormal'}
if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){Show-Status;exit 0}
if((Get-Service Schedule).Status -ne 'Running'){throw 'Windows Task Scheduler is not running'}
$launchLock=[IO.File]::Open((Join-Path $run 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $task=Get-Task
    if($task -and [string]$task.State -in @('Running','Queued')){Show-Status;exit 0}
    $workerLock=[IO.File]::Open((Join-Path $run 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $workerLock.Dispose()
    if(Get-Process -Name MATLAB -ErrorAction SilentlyContinue){throw 'MATLAB already running; inspect before resuming'}
    $manifest=Get-Content -LiteralPath (Join-Path $run 'launcher_manifest.json') -Raw | ConvertFrom-Json
    $expected=@($manifest | Where-Object {$_.file -eq 'psx_worker.ps1'})
    if($expected.Count -ne 1 -or (Get-FileHash -LiteralPath $workerScript -Algorithm SHA256).Hash.ToLower() -ne $expected[0].sha256){throw 'Frozen worker changed'}
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$workerScript+'" -RunDirectory "'+$run+'"'
    if(-not $spec.smoke_test){$arguments+=' -AuthorizeFormal'}
    $taskAction=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $snapshot
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    $settings.StartWhenAvailable=$false;$settings.RestartCount=0;$settings.WakeToRun=$false
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $definition=New-ScheduledTask -Action $taskAction -Settings $settings -Principal $principal -Description $description
    Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force | Out-Null
    $registered=Get-Task
    if(@($registered.Triggers | Where-Object {$null -ne $_}).Count -ne 0 -or $registered.Settings.RestartCount -ne 0 -or $registered.Settings.StartWhenAvailable -or $registered.Settings.WakeToRun -or $registered.Settings.ExecutionTimeLimit -ne 'PT0S'){throw 'Demand-only task policy verification failed; not started'}
    $receipt=[ordered]@{requested_utc=[DateTime]::UtcNow.ToString('o');task_name=$taskName;run_directory=$run;
        task_owner='Windows Task Scheduler';manual_start_only=$true;trigger_count=0;automatic_restart=$false;
        execution_time_limit=$registered.Settings.ExecutionTimeLimit;worker_sha256=$expected[0].sha256;
        account_must_remain_logged_in=$true;launcher_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()}
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'demand_launcher_status.json') -Encoding utf8
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $run ('manual_task_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.xml')) -Encoding utf8
    Start-ScheduledTask -TaskName $taskName
    $pauseMarker=Join-Path $run 'psx_paused.json'
    if(Test-Path -LiteralPath $pauseMarker){
        Move-Item -LiteralPath $pauseMarker -Destination (Join-Path $run ('paused_until_manual_resume_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.json'))
    }
    Show-Status
}finally{$launchLock.Dispose()}
