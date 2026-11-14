[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory)
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
if(-not $run.StartsWith('C:\new\results\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($run) -notmatch '^psx_[A-Za-z0-9_-]+$'){throw 'Unexpected run directory'}
$taskName='PSX-'+[IO.Path]::GetFileName($run)
$task=Get-ScheduledTask -TaskName $taskName
if($task.Description -ne ('PSX demand-only manual worker. RunDirectory='+$run)){throw 'Task ownership mismatch'}
$launchLock=[IO.File]::Open((Join-Path $run 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
function Save-Json([string]$Path,$Value){
    $temp=$Path+'.pause.'+$PID+'.tmp'
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
try{
    $worker=Get-Content -LiteralPath (Join-Path $run 'worker_status.json') -Raw | ConvertFrom-Json
    $application=Get-Content -LiteralPath (Join-Path $run 'status.json') -Raw | ConvertFrom-Json
    $allProcesses=@(Get-CimInstance Win32_Process)
    $root=@($allProcesses | Where-Object {$_.ProcessId -eq [int]$worker.worker_pid})
    $workerScript=Join-Path $run 'launcher_snapshot\psx_worker.ps1'
    if($root.Count -ne 1 -or $root[0].CommandLine -notlike ('*'+$workerScript+'*') -or $root[0].CreationDate.ToUniversalTime() -lt ([datetime]$worker.started_utc).ToUniversalTime().AddSeconds(-5)){throw 'Expected live worker identity is not verified; no process was stopped'}
    $owned=@($root[0])
    do{
        $ownedIds=@($owned | ForEach-Object {[int]$_.ProcessId})
        $children=@($allProcesses | Where-Object {$_.ParentProcessId -in $ownedIds -and $_.ProcessId -notin $ownedIds -and $_.CreationDate -ge $root[0].CreationDate})
        $owned+= $children
    }while($children.Count -gt 0)
    $history=Join-Path $run ('pause_history\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
    New-Item -ItemType Directory -Path $history | Out-Null
    foreach($name in @('worker_status.json','status.json','progress_original.json','progress_independent.json','demand_launcher_status.json')){
        $source=Join-Path $run $name
        if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (Join-Path $history $name)}
    }
    $owned | Select-Object ProcessId,ParentProcessId,Name,CreationDate,CommandLine | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $history 'process_tree_before.json') -Encoding utf8
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $history 'task_before.xml') -Encoding utf8
    $pause=[ordered]@{state='pausing';requested_utc=[DateTime]::UtcNow.ToString('o');reason='User requested pause to use the computer';resume_requires='Explicit user instruction; no automatic restart';task_name=$taskName;history_directory=$history}
    Save-Json (Join-Path $run 'psx_paused.json') $pause
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Stop-ScheduledTask -TaskName $taskName
    $stopped=@()
    foreach($before in @($owned | Sort-Object CreationDate -Descending)){
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$before.ProcessId)
        if($current -and $current.CreationDate -eq $before.CreationDate -and $current.CommandLine -eq $before.CommandLine){
            Stop-Process -Id ([int]$current.ProcessId) -Force -ErrorAction SilentlyContinue
            $stopped+=[int]$current.ProcessId
        }
    }
    Start-Sleep -Seconds 2
    $remaining=@()
    foreach($before in $owned){
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$before.ProcessId)
        if($current -and $current.CreationDate -eq $before.CreationDate){$remaining+=$current}
    }
    $taskAfter=Get-ScheduledTask -TaskName $taskName
    $stopAudit=[ordered]@{stopped_utc=[DateTime]::UtcNow.ToString('o');remaining_verified_processes=$remaining.Count;explicitly_stopped_pids=$stopped;task_state=[string]$taskAfter.State;task_enabled=$taskAfter.Settings.Enabled;trigger_count=@($taskAfter.Triggers | Where-Object {$null -ne $_}).Count;history_directory=$history}
    Save-Json (Join-Path $history 'stop_verified.json') $stopAudit
    if($remaining.Count -gt 0 -or $taskAfter.Settings.Enabled){throw 'Stop verification incomplete; inspect saved stop audit'}
    $finished=[DateTime]::UtcNow.ToString('o')
    $application | Add-Member -NotePropertyName previous_phase -NotePropertyValue $application.phase -Force
    $application.state='paused';$application.phase='paused_by_user';$application.message='Explicitly paused for other computer use; resume only on user instruction.';$application.updated_utc=$finished
    $worker.state='paused';$worker.finished_utc=$finished;$worker.exit_code=$null
    $worker | Add-Member -NotePropertyName stop_kind -NotePropertyValue 'explicit_user_pause_process_termination' -Force
    Save-Json (Join-Path $run 'status.json') $application
    Save-Json (Join-Path $run 'worker_status.json') $worker
    $counts=@{}
    $recordAudit=@()
    foreach($panel in @('original','independent')){
        $folder=Join-Path $run ($panel+'_records')
        $records=@();$seals=@()
        if(Test-Path -LiteralPath $folder){
            $records=@(Get-ChildItem -LiteralPath $folder -Filter 'trial_*.mat' -File | Sort-Object Name)
            $seals=@(Get-ChildItem -LiteralPath $folder -Filter 'trial_*.mat.sha256.json' -File)
        }
        if($records.Count -ne $seals.Count){throw ('Record/seal count mismatch in '+$panel+'; files preserved')}
        for($index=0;$index -lt $records.Count;$index++){
            $record=$records[$index]
            if($record.Name -ne ('trial_{0:D6}.mat' -f ($index+1))){throw ('Noncontiguous record sequence: '+$record.Name)}
            $seal=Get-Content -LiteralPath ($record.FullName+'.sha256.json') -Raw | ConvertFrom-Json
            $hash=(Get-FileHash -LiteralPath $record.FullName -Algorithm SHA256).Hash.ToLower()
            if($record.Length -ne [long]$seal.bytes -or $hash -ne $seal.sha256){throw ('Record integrity mismatch: '+$record.Name)}
        }
        $counts[$panel]=$records.Count
        $recordAudit+=[ordered]@{panel=$panel;committed_records=$records.Count;contiguous=$true;all_sizes_and_sha256_verified=$true}
    }
    $modelLock=Get-Content -LiteralPath (Join-Path $run 'MODEL_LOCK.json') -Raw | ConvertFrom-Json
    $modelHash=(Get-FileHash -LiteralPath (Join-Path $run 'combined_bundle.mat') -Algorithm SHA256).Hash.ToLower()
    if($modelHash -ne $modelLock.bundle_sha256){throw 'Model lock mismatch; files preserved'}
    $pause.state='explicitly_paused';$pause.stopped_utc=$finished;$pause.completed_training_fits=36
    $pause.committed_original_trajectories=$counts.original;$pause.committed_independent_trajectories=$counts.independent
    $pause.next_original_trial=$counts.original+1;$pause.committed_records_and_model_integrity_verified=$true;$pause.task_disabled=$true
    Save-Json (Join-Path $history 'integrity_verified.json') ([ordered]@{verified_utc=[DateTime]::UtcNow.ToString('o');panels=$recordAudit;model_sha256=$modelHash;model_lock_matches=$true})
    Save-Json (Join-Path $run 'psx_paused.json') $pause
    $pause | ConvertTo-Json -Depth 6
}finally{$launchLock.Dispose()}
