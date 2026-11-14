param(
    [ValidateSet('Status','Smoke','Start','Resume')][string]$Action='Status',
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [switch]$AuthorizeFormal
)
$ErrorActionPreference='Stop'
$run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
$allowed=[IO.Path]::GetFullPath('C:\new\results').TrimEnd('\')+'\'
if(-not $run.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($run) -notmatch '^psx_[A-Za-z0-9_-]+$'){throw 'Unexpected run directory'}
$spec=Get-Content -LiteralPath (Join-Path $run 'spec.json') -Raw | ConvertFrom-Json
$statusFile=Join-Path $run 'status.json'
$workerFile=Join-Path $run 'worker_status.json'
if($Action -eq 'Status'){
    if(Test-Path -LiteralPath $statusFile){Get-Content -LiteralPath $statusFile -Raw}
    if(Test-Path -LiteralPath $workerFile){Get-Content -LiteralPath $workerFile -Raw}
    exit 0
}
if(-not $spec.smoke_test -and -not $AuthorizeFormal){throw 'Formal execution requires an explicit manual -AuthorizeFormal switch.'}
if($Action -eq 'Smoke' -and -not $spec.smoke_test){throw 'Smoke action cannot launch a formal run; use Start or Resume with -AuthorizeFormal.'}
$snapshotDirectory=Join-Path $run 'source_snapshot'
if(-not (Test-Path -LiteralPath $snapshotDirectory -PathType Container)){throw 'Frozen snapshot directory is missing.'}
$lockStream=[IO.File]::Open((Join-Path $run 'launcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    if(Test-Path -LiteralPath (Join-Path $run 'COMPLETE.json')){Write-Output 'Already complete; no process started.';exit 0}
    if(Test-Path -LiteralPath $workerFile){
        $old=Get-Content -LiteralPath $workerFile -Raw | ConvertFrom-Json
        if($old.state -eq 'running' -and (Get-Process -Id $old.worker_pid -ErrorAction SilentlyContinue)){
            throw 'An existing worker is still alive; duplicate launch refused.'
        }
    }
    $helper=Join-Path $PSScriptRoot 'psx_worker.ps1'
    $pwsh=(Get-Process -Id $PID).Path
    $arguments=@('-NoProfile','-File',('"'+$helper+'"'),'-RunDirectory',('"'+$run+'"'))
    if(-not $spec.smoke_test){$arguments+='-AuthorizeFormal'}
    $worker=Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $snapshotDirectory -PassThru
    [pscustomobject]@{worker_pid=$worker.Id;run_directory=$run;action=$Action;smoke_test=$spec.smoke_test;formal_authorized=(-not $spec.smoke_test -and [bool]$AuthorizeFormal);automatic_restart=$false}|ConvertTo-Json
}finally{$lockStream.Dispose()}
