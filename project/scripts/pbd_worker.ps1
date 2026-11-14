[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory,[switch]$AuthorizeExploration)
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
$results=[IO.Path]::GetFullPath('C:\new\results').TrimEnd('\')
if([IO.Path]::GetDirectoryName($run) -ne $results -or [IO.Path]::GetFileName($run) -notmatch '^pbd_[A-Za-z0-9_-]+$'){
    throw 'RunDirectory must be an immediate C:\new\results\pbd_* directory.'
}
if(-not $AuthorizeExploration){throw 'Execution requires explicit -AuthorizeExploration.'}
if(-not (Test-Path -LiteralPath $run -PathType Container)){throw 'Run directory does not exist.'}
$frozenWorker=Join-Path $run 'launcher_snapshot\pbd_worker.ps1'
if([IO.Path]::GetFullPath($PSCommandPath) -ne $frozenWorker){throw 'Worker must execute from this run launcher_snapshot.'}
$workerLock=[IO.File]::Open((Join-Path $run 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$globalGuard=$null
$attempt=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'_'+$PID
$attemptDirectory=Join-Path $run ('attempts\'+$attempt)
$stateFile=Join-Path $run 'worker_status.json'
$state=[ordered]@{
    state='starting';attempt=$attempt;attempt_directory=$attemptDirectory;worker_pid=$PID;worker_created_utc=$null
    matlab_pid=$null;matlab_created_utc=$null;started_utc=[DateTime]::UtcNow.ToString('o');finished_utc=$null
    exit_code=$null;worker_exit_code=$null;automatic_restart=$false;single_compute_thread=$true
}
$workerExitCode=1
function Save-Json([string]$Path,$Value){
    $temp=$Path+'.'+$PID+'.tmp'
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Write-State{Save-Json $stateFile $state}
function Mark-PrelaunchPause{
    $state.state='paused_before_matlab_start'
    $request=Get-Content -LiteralPath (Join-Path $run 'PAUSE_REQUEST.json') -Raw | ConvertFrom-Json
    Save-Json (Join-Path $run 'PAUSED.json') ([ordered]@{
        state='paused';paused_utc=[DateTime]::UtcNow.ToString('o');reason=$request.reason
        stop_kind='cooperative_before_matlab_start';attempt=$attempt;exit_code=$null;automatic_restart=$false
    })
}
try{
    New-Item -ItemType Directory -Path $attemptDirectory -ErrorAction Stop | Out-Null
    New-Item -ItemType File -Path (Join-Path $attemptDirectory 'stdout.log') -ErrorAction Stop | Out-Null
    New-Item -ItemType File -Path (Join-Path $attemptDirectory 'stderr.log') -ErrorAction Stop | Out-Null
    if(Test-Path -LiteralPath $stateFile){Copy-Item -LiteralPath $stateFile -Destination (Join-Path $attemptDirectory 'previous_worker_status.json')}
    $self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)
    $state.worker_created_utc=$self.CreationDate.ToUniversalTime().ToString('o')
    Write-State
    $manifest=Get-Content -LiteralPath (Join-Path $run 'launcher_manifest.json') -Raw | ConvertFrom-Json
    $expected=@($manifest | Where-Object {$_.file -eq 'pbd_worker.ps1'})
    if($expected.Count -ne 1 -or [string]$expected[0].sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $frozenWorker -Algorithm SHA256).Hash -ne [string]$expected[0].sha256){throw 'Frozen worker manifest/hash verification failed.'}
    $snapshot=Join-Path $run 'source_snapshot'
    if(-not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $snapshot 'run_pbd_job.m') -PathType Leaf)){throw 'Frozen source_snapshot/run_pbd_job.m is missing.'}
    if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){
        $state.state='complete_preexisting';$workerExitCode=0
    }elseif(Test-Path -LiteralPath (Join-Path $run 'PAUSE_REQUEST.json')){
        Mark-PrelaunchPause;$workerExitCode=0
    }else{
        # Held for the complete MATLAB lifetime; excludes simultaneous PBD launches across run directories.
        $globalGuard=[IO.File]::Open((Join-Path $results '.pbd_matlab.guard.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if(Get-Process -Name MATLAB -ErrorAction SilentlyContinue){throw 'MATLAB is already running; refusing a second MATLAB process.'}
        $matlabExe='D:\Program Files\MATLAB\R2026a\bin\matlab.exe'
        if(-not (Test-Path -LiteralPath $matlabExe -PathType Leaf)){throw 'Configured MATLAB executable is missing.'}
        $env:OMP_NUM_THREADS='1'
        $env:MKL_NUM_THREADS='1'
        $env:OPENBLAS_NUM_THREADS='1'
        $env:NUMEXPR_NUM_THREADS='1'
        $matlabSnapshot=$snapshot.Replace('\','/').Replace("'","''")
        $matlabRun=$run.Replace('\','/').Replace("'","''")
        $expression="addpath('$matlabSnapshot');run_pbd_job('$matlabRun',true)"
        $arguments=@('-singleCompThread','-batch',('"'+$expression+'"'))
        $state.matlab_command=$expression
        $state.matlab_arguments=$arguments
        Write-State
        if(Test-Path -LiteralPath (Join-Path $run 'PAUSE_REQUEST.json')){
            Mark-PrelaunchPause;$workerExitCode=0
        }else{
            $matlab=Start-Process -FilePath $matlabExe -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $snapshot -PassThru `
                -RedirectStandardOutput (Join-Path $attemptDirectory 'stdout.log') -RedirectStandardError (Join-Path $attemptDirectory 'stderr.log')
            $null=$matlab.Handle
            $state.matlab_pid=$matlab.Id
            $child=Get-CimInstance Win32_Process -Filter ('ProcessId='+$matlab.Id)
            if($child){$state.matlab_created_utc=$child.CreationDate.ToUniversalTime().ToString('o')}
            $state.state='running';Write-State
            $matlab.WaitForExit()
            $matlab.Refresh()
            $state.exit_code=$matlab.ExitCode
            if($null -eq $state.exit_code){throw 'MATLAB ended without an observable exit code.'}
            $workerExitCode=[int]$state.exit_code
            if($state.exit_code -eq 0 -and (Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json'))){$state.state='complete'}
            elseif($state.exit_code -eq 0 -and (Test-Path -LiteralPath (Join-Path $run 'PAUSED.json'))){$state.state='paused'}
            else{
                $state.state='failed'
                if($state.exit_code -eq 0){$state.error='MATLAB returned zero without COMPLETE.json or PAUSED.json.';$workerExitCode=1}
            }
        }
    }
}catch{
    $state.state='failed'
    $state.error=$_.Exception.Message
    $workerExitCode=1
    # exit_code stays null if MATLAB was never launched or no real code was observed.
    if(Test-Path -LiteralPath $attemptDirectory){$_ | Out-String | Set-Content -LiteralPath (Join-Path $attemptDirectory 'worker_error.log') -Encoding utf8}
}finally{
    $state.finished_utc=[DateTime]::UtcNow.ToString('o')
    $state.worker_exit_code=$workerExitCode
    try{
        Write-State
        if(Test-Path -LiteralPath $attemptDirectory){Save-Json (Join-Path $attemptDirectory 'worker_exit.json') $state}
    }finally{
        if($globalGuard){$globalGuard.Dispose()}
        $workerLock.Dispose()
    }
}
exit $workerExitCode
