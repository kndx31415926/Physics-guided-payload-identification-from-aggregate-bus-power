param([Parameter(Mandatory=$true)][string]$RunDirectory,[switch]$AuthorizeFormal)
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
$allowed=[IO.Path]::GetFullPath('C:\new\results').TrimEnd('\')+'\'
if(-not $run.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($run) -notmatch '^psx_[A-Za-z0-9_-]+$'){throw 'Unexpected run directory'}
$spec=Get-Content -LiteralPath (Join-Path $run 'spec.json') -Raw | ConvertFrom-Json
if(-not $spec.smoke_test -and -not $AuthorizeFormal){throw 'Formal execution requires an explicit manual -AuthorizeFormal switch.'}
$snapshotDirectory=Join-Path $run 'source_snapshot'
if(-not (Test-Path -LiteralPath $snapshotDirectory -PathType Container)){throw 'Frozen snapshot directory is missing.'}
$lockStream=[IO.File]::Open((Join-Path $run 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$state=[ordered]@{state='running';worker_pid=$PID;matlab_pid=$null;started_utc=[DateTime]::UtcNow.ToString('o');finished_utc=$null;exit_code=$null;automatic_restart=$false;attempt=$stamp}
$stateFile=Join-Path $run 'worker_status.json'
function Write-State{
    $temp=$stateFile+'.'+$PID+'.tmp'
    $state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $stateFile -Force
}
try{
    if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){$state.state='complete';$state.exit_code=0;exit 0}
    Write-State
    $snapshot=$snapshotDirectory.Replace('\','/').Replace("'","''")
    $matlabRun=$run.Replace('\','/').Replace("'","''")
    $formalArgument=if($spec.smoke_test){'false'}else{'true'}
    $expression="addpath('$snapshot');run_psx_job('$matlabRun',$formalArgument);"
    $arguments=@('-batch',('"'+$expression+'"'))
    $matlab=Start-Process -FilePath 'D:\Program Files\MATLAB\R2026a\bin\matlab.exe' -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $snapshotDirectory -PassThru `
        -RedirectStandardOutput (Join-Path $run ($stamp+'.stdout.log')) -RedirectStandardError (Join-Path $run ($stamp+'.stderr.log'))
    $state.matlab_pid=$matlab.Id;Write-State
    $matlab.WaitForExit();$state.exit_code=$matlab.ExitCode
    $state.state=if($matlab.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json'))){'complete'}else{'failed'}
}catch{
    $state.state='failed';$state.exit_code=1;$state.error=$_.Exception.Message
}finally{
    $state.finished_utc=[DateTime]::UtcNow.ToString('o');Write-State
    $state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $run ($stamp+'.worker_exit.json')) -Encoding utf8
    $lockStream.Dispose()
}
exit ([int]$state.exit_code)
