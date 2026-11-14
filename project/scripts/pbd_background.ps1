[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [ValidateSet('Status','Start','Pause')][string]$Action='Status',
    [switch]$AuthorizeExploration,
    [string]$Reason='Manual exploration pause requested',
    [switch]$Force
)
# Demand-only Windows-owned execution. Closing the launching application is safe; signing out is not supported.
# No timer, boot, logon, retry, or automatic resume is installed.
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
$results=[IO.Path]::GetFullPath('C:\new\results').TrimEnd('\')
if([IO.Path]::GetDirectoryName($run) -ne $results -or [IO.Path]::GetFileName($run) -notmatch '^pbd_[A-Za-z0-9_-]+$'){
    throw 'RunDirectory must be an immediate C:\new\results\pbd_* directory.'
}
if(-not (Test-Path -LiteralPath $run -PathType Container)){throw 'Run directory does not exist.'}
if($Force -and $Action -ne 'Pause'){throw '-Force is only valid with -Action Pause.'}
$taskName='PBD-'+[IO.Path]::GetFileName($run)
$taskPath='\'
$description='PBD demand-only manual exploration worker. RunDirectory='+$run
$snapshot=Join-Path $run 'source_snapshot'
$workerScript=Join-Path $run 'launcher_snapshot\pbd_worker.ps1'
$powerShellExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskArguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$workerScript+'" -RunDirectory "'+$run+'" -AuthorizeExploration'
function Read-Json([string]$Name){
    $file=Join-Path $run $Name
    if(Test-Path -LiteralPath $file){Get-Content -LiteralPath $file -Raw | ConvertFrom-Json}
}
function Save-Json([string]$Path,$Value){
    $temp=$Path+'.'+$PID+'.tmp'
    $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function New-History([string]$Kind){
    $directory=Join-Path $run ('launcher_history\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'_'+$PID+'_'+$Kind)
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    foreach($name in @('worker_status.json','status.json','demand_launcher_status.json','PAUSE_REQUEST.json','PAUSED.json')){
        $source=Join-Path $run $name
        if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (Join-Path $directory $name)}
    }
    return $directory
}
function Get-OwnedTask{
    # Enumerating also distinguishes an absent task from a scheduler/permission failure.
    $matches=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -eq $taskName -and $_.TaskPath -eq $taskPath})
    if($matches.Count -gt 1){throw 'Ambiguous task ownership; no task was changed.'}
    $task=$null
    if($matches.Count -eq 1){$task=$matches[0]}
    if($task){
        $actions=@($task.Actions)
        if($task.Description -ne $description -or $actions.Count -ne 1 -or
            $actions[0].Execute -ne $powerShellExe -or $actions[0].Arguments -ne $taskArguments -or
            $actions[0].WorkingDirectory -ne $snapshot){throw 'Task ownership mismatch; task was not changed.'}
    }
    return $task
}
function Get-LiveWorker($State){
    if(-not $State -or -not $State.worker_pid -or -not $State.worker_created_utc){return $null}
    $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$State.worker_pid)
    if($candidate -and $candidate.Name -ieq 'powershell.exe' -and
        $candidate.CommandLine -and
        $candidate.CommandLine.IndexOf(('"'+$workerScript+'"'),[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $candidate.CommandLine.IndexOf(('"'+$run+'"'),[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $candidate.CreationDate.ToUniversalTime().Ticks -eq ([datetime]$State.worker_created_utc).ToUniversalTime().Ticks){return $candidate}
    return $null
}
function Show-Status{
    $task=Get-OwnedTask
    $taskInfo=$null
    if($task){$taskInfo=Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath}
    $state=Read-Json 'worker_status.json'
    $live=Get-LiveWorker $state
    $request=Read-Json 'PAUSE_REQUEST.json'
    $paused=Read-Json 'PAUSED.json'
    $effective='not_started'
    if($state){$effective=[string]$state.state}
    if($state -and $state.state -in @('starting','running') -and -not $live){$effective='interrupted_process_missing'}
    if($request){$effective=if($live){'pause_requested'}else{'pause_requested_worker_absent'}}
    if($paused){$effective=if($live){'pausing'}else{'paused'}}
    if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){$effective='complete'}
    [ordered]@{
        run_directory=$run;effective_state=$effective;task_name=$taskName
        task_state=$(if($task){[string]$task.State}else{'not_registered'})
        task_enabled=$(if($task){$task.Settings.Enabled}else{$false})
        last_task_result=$(if($taskInfo){$taskInfo.LastTaskResult}else{$null})
        live_worker_pid=$(if($live){[int]$live.ProcessId}else{$null})
        worker=$state;application=(Read-Json 'status.json');pause_request=$request;paused=$paused
        trigger_count=$(if($task){@($task.Triggers | Where-Object {$null -ne $_}).Count}else{0})
        automatic_restart=$false;manual_start_requires='-Action Start -AuthorizeExploration'
        account_must_remain_logged_in=$true
    } | ConvertTo-Json -Depth 16
}
function Assert-FrozenWorker{
    if(-not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $snapshot 'run_pbd_job.m') -PathType Leaf)){
        throw 'Frozen source_snapshot/run_pbd_job.m is missing.'
    }
    $manifest=Read-Json 'launcher_manifest.json'
    $expected=@($manifest | Where-Object {$_.file -eq 'pbd_worker.ps1'})
    if($expected.Count -ne 1 -or [string]$expected[0].sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        -not (Test-Path -LiteralPath $workerScript -PathType Leaf)){
        throw 'launcher_manifest.json must contain exactly one pbd_worker.ps1 entry with a SHA256 hash.'
    }
    $hash=(Get-FileHash -LiteralPath $workerScript -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -ne ([string]$expected[0].sha256).ToLowerInvariant()){throw 'Frozen worker SHA256 mismatch.'}
    return $hash
}
function Assert-DemandOnly($Task){
    if(@($Task.Triggers | Where-Object {$null -ne $_}).Count -ne 0 -or
        $Task.Settings.RestartCount -ne 0 -or $Task.Settings.StartWhenAvailable -or
        $Task.Settings.WakeToRun -or $Task.Settings.ExecutionTimeLimit -ne 'PT0S' -or
        -not $Task.Settings.Hidden -or [string]$Task.Settings.MultipleInstances -ne 'IgnoreNew'){
        throw 'Demand-only task policy verification failed; not started.'
    }
}
if($Action -eq 'Status'){Show-Status;exit 0}
if($Action -eq 'Start' -and -not $AuthorizeExploration){throw 'Start requires explicit -AuthorizeExploration.'}
if($Action -eq 'Pause' -and [string]::IsNullOrWhiteSpace($Reason)){throw 'Pause requires a nonempty -Reason.'}
$launchLock=[IO.File]::Open((Join-Path $run 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $task=Get-OwnedTask
    if($Action -eq 'Start'){
        $workerHash=Assert-FrozenWorker
        if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){Show-Status;exit 0}
        if((Get-Service Schedule).Status -ne 'Running'){throw 'Windows Task Scheduler is not running.'}
        if($task -and [string]$task.State -in @('Running','Queued')){throw 'This task is already running or queued; inspect Status.'}
        $workerLock=[IO.File]::Open((Join-Path $run 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $workerLock.Dispose()
        $globalGuard=[IO.File]::Open((Join-Path $results '.pbd_matlab.guard.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $globalGuard.Dispose()
        if(Get-Process -Name MATLAB -ErrorAction SilentlyContinue){throw 'MATLAB is already running; no new MATLAB was started.'}
        if(-not (Test-Path -LiteralPath 'D:\Program Files\MATLAB\R2026a\bin\matlab.exe' -PathType Leaf)){throw 'Configured MATLAB executable is missing.'}
        $history=New-History 'start'
        if($task){Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Set-Content -LiteralPath (Join-Path $history 'task_before.xml') -Encoding utf8}
        $taskAction=New-ScheduledTaskAction -Execute $powerShellExe -Argument $taskArguments -WorkingDirectory $snapshot
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
        $settings.StartWhenAvailable=$false
        $settings.RestartCount=0
        $settings.WakeToRun=$false
        $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $definition=New-ScheduledTask -Action $taskAction -Settings $settings -Principal $principal -Description $description
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -InputObject $definition -Force | Out-Null
        $registered=Get-OwnedTask
        try{Assert-DemandOnly $registered}catch{Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null;throw}
        Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Set-Content -LiteralPath (Join-Path $history 'task_registered.xml') -Encoding utf8
        foreach($name in @('PAUSE_REQUEST.json','PAUSED.json')){
            $marker=Join-Path $run $name
            if(Test-Path -LiteralPath $marker){Move-Item -LiteralPath $marker -Destination (Join-Path $history ('archived_'+$name))}
        }
        $receipt=[ordered]@{
            requested_utc=[DateTime]::UtcNow.ToString('o');task_name=$taskName;run_directory=$run
            task_owner='Windows Task Scheduler';manual_start_only=$true;trigger_count=0;automatic_restart=$false
            exploration_explicitly_authorized=$true;single_compute_thread=$true
            worker_sha256=$workerHash;launcher_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
            execution_time_limit=$registered.Settings.ExecutionTimeLimit;account_must_remain_logged_in=$true
            history_directory=$history;state='start_requested'
        }
        Save-Json (Join-Path $history 'start_receipt.json') $receipt
        Save-Json (Join-Path $run 'demand_launcher_status.json') $receipt
        try{Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath}catch{
            $receipt.state='start_request_failed';$receipt.error=$_.Exception.Message
            Save-Json (Join-Path $history 'start_receipt.json') $receipt
            Save-Json (Join-Path $run 'demand_launcher_status.json') $receipt
            Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
            foreach($name in @('PAUSE_REQUEST.json','PAUSED.json')){
                $archived=Join-Path $history ('archived_'+$name)
                if(Test-Path -LiteralPath $archived){Copy-Item -LiteralPath $archived -Destination (Join-Path $run $name) -Force}
            }
            throw
        }
        Show-Status
        exit 0
    }
    $history=New-History 'pause'
    if($task){Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Set-Content -LiteralPath (Join-Path $history 'task_before.xml') -Encoding utf8}
    $request=[ordered]@{
        state='pause_requested';requested_utc=[DateTime]::UtcNow.ToString('o');reason=$Reason
        mode=$(if($Force){'force_requested'}else{'cooperative_record_boundary'})
        task_name=$taskName;history_directory=$history;automatic_restart=$false
        resume_requires='Explicit -Action Start -AuthorizeExploration; no automatic resume'
    }
    Save-Json (Join-Path $run 'PAUSE_REQUEST.json') $request
    Save-Json (Join-Path $history 'pause_request.json') $request
    if($task){Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null}
    if(-not $Force){Show-Status;exit 0}
    $state=Read-Json 'worker_status.json'
    $root=Get-LiveWorker $state
    if(-not $root){
        # Do not infer ownership of any process from a stale PID or a MATLAB name.
        throw 'No live owned worker was verified. Cooperative request was saved and task disabled; no process was stopped.'
    }
    if($state.state -eq 'starting' -or -not $state.matlab_pid -or -not $state.matlab_created_utc){
        throw 'Worker launch is in progress. Cooperative request was saved; retry Force after Status confirms a MATLAB PID.'
    }
    $allProcesses=@(Get-CimInstance Win32_Process)
    $owned=@($root)
    do{
        $ids=@($owned | ForEach-Object {[int]$_.ProcessId})
        $children=@($allProcesses | Where-Object {$_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids -and $_.CreationDate -ge $root.CreationDate})
        $owned+=$children
    }while($children.Count -gt 0)
    $matlab=@($owned | Where-Object {$_.ProcessId -eq [int]$state.matlab_pid -and $_.Name -ieq 'MATLAB.exe' -and $_.CreationDate.ToUniversalTime().Ticks -eq ([datetime]$state.matlab_created_utc).ToUniversalTime().Ticks})
    if($matlab.Count -ne 1){throw 'MATLAB identity/ancestry could not be verified. Cooperative request remains; no process was stopped.'}
    $owned | Select-Object ProcessId,ParentProcessId,Name,CreationDate,CommandLine | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $history 'process_tree_before.json') -Encoding utf8
    Save-Json (Join-Path $history 'force_stop_intent.json') ([ordered]@{requested_utc=[DateTime]::UtcNow.ToString('o');reason=$Reason;attempt=$state.attempt;worker_pid=$state.worker_pid;matlab_pid=$state.matlab_pid;exit_code=$null})
    $stopped=@()
    # Descendants first and the worker last. Recheck both creation time and command line before every stop.
    foreach($before in @($owned | Sort-Object CreationDate -Descending)){
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$before.ProcessId)
        if($current -and $current.CreationDate -eq $before.CreationDate -and $current.CommandLine -eq $before.CommandLine){
            Stop-Process -Id ([int]$current.ProcessId) -Force -ErrorAction Stop
            $stopped+=[int]$current.ProcessId
        }
    }
    $remaining=@()
    foreach($before in $owned){
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$before.ProcessId)
        if($current -and $current.CreationDate -eq $before.CreationDate){$remaining+=[int]$current.ProcessId}
    }
    $taskAfter=Get-OwnedTask
    $audit=[ordered]@{
        stopped_utc=[DateTime]::UtcNow.ToString('o');reason=$Reason;attempt=$state.attempt
        explicitly_stopped_pids=$stopped;remaining_verified_pids=$remaining
        task_enabled=$(if($taskAfter){$taskAfter.Settings.Enabled}else{$false})
        stop_kind='explicit_force_process_termination';exit_code=$null;history_directory=$history
    }
    Save-Json (Join-Path $history 'force_stop_audit.json') $audit
    if($remaining.Count -gt 0 -or ($taskAfter -and $taskAfter.Settings.Enabled)){throw 'Force stop verification incomplete; inspect force_stop_audit.json.'}
    if([string]$state.attempt -match '^\d{8}T\d{9}Z_\d+$'){
        $attemptDirectory=Join-Path $run ('attempts\'+$state.attempt)
        if(Test-Path -LiteralPath $attemptDirectory -PathType Container){
            Save-Json (Join-Path $attemptDirectory 'force_stop_audit.json') $audit
            $exitRecord=Join-Path $attemptDirectory 'worker_exit.json'
            if(-not (Test-Path -LiteralPath $exitRecord)){
                Save-Json $exitRecord ([ordered]@{
                    state='interrupted_forced';attempt=$state.attempt;finished_utc=[DateTime]::UtcNow.ToString('o')
                    worker_pid=$state.worker_pid;matlab_pid=$state.matlab_pid;exit_code=$null;worker_exit_code=$null
                    stop_kind='explicit_force_process_termination';reason=$Reason;history_directory=$history
                })
            }
        }
    }
    Save-Json (Join-Path $run 'PAUSED.json') ([ordered]@{
        state='paused';paused_utc=[DateTime]::UtcNow.ToString('o');reason=$Reason
        stop_kind='explicit_force_process_termination';attempt=$state.attempt;exit_code=$null
        history_directory=$history;automatic_restart=$false
    })
    # Original worker_status, application status, logs and actual exit codes remain untouched.
    Show-Status
}finally{$launchLock.Dispose()}
