param([switch]$Execute,[string]$ExpectedSourceSha256,[string]$ReferenceFeedbackPath,[ValidateSet('inward10','inward20')][string]$Profile='inward10')
$ErrorActionPreference='Stop'
$source=if($Profile -eq 'inward20'){'C:\new\scripts\roarm_shoulder_inward20_single_test.ps1'}else{'C:\new\scripts\roarm_shoulder_inward_single_test.ps1'}
$scope=if($Profile -eq 'inward20'){'Exactly one T101 joint2 target, new measured shoulder +20 deg from the narrow [-90,-85] deg initial interval; other axes receive no target. No torque/PID/calibration/home write.'}else{'Exactly one T101 joint2 target, new measured shoulder +10 deg from the narrow [-95,-90) deg initial interval; other axes receive no target. No torque/PID/calibration/home write.'}
$stop='C:\new\hardware_stop.flag'
if(-not $Execute){
    Write-Output 'Preview only. For this explicitly authorized shoulder-only inward target: archive the prior stop flag, run the verified single-target script, then restore the stop flag even if the child reports failure.'
    exit 0
}
if($ExpectedSourceSha256 -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Exact independently reviewed source hash is required'}
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $ExpectedSourceSha256){throw 'Motion source changed after review'}
if(-not(Test-Path -LiteralPath $ReferenceFeedbackPath -PathType Leaf)){throw 'Reference file missing'}
if(-not(Test-Path -LiteralPath $stop -PathType Leaf)){throw 'Expected prior stop record is absent; no action taken'}
$run=Join-Path 'C:\new\results\hardware_control' ('authorized_inward_once_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $run 'executed_launcher.ps1')
$verifiedSource=Join-Path $run 'reviewed_motion_script.ps1'
Copy-Item -LiteralPath $source -Destination $verifiedSource
if((Get-FileHash -LiteralPath $verifiedSource -Algorithm SHA256).Hash -ne $ExpectedSourceSha256){throw 'Snapshot differs from reviewed source; stop flag untouched'}
$archivedStop=Join-Path $run 'previous_hardware_stop.flag'
Copy-Item -LiteralPath $stop -Destination $archivedStop
$previousStopHash=(Get-FileHash -LiteralPath $archivedStop -Algorithm SHA256).Hash
$restorationSource=$archivedStop
$journal=[ordered]@{
    user_authorization=$(if($Profile -eq 'inward20'){'只动肩部，底座、肘、夹爪不动；全程悬空，没有接触或手扶；动大点吧'}else{'只动肩部，底座、肘、夹爪不动'})
    context='User supplied the new right-side extended pose and stated movement to that angle was clear. Root explained this one inward target and no automatic return.'
    profile=$Profile
    scope=$scope
    source_sha256=$ExpectedSourceSha256
    reference=$ReferenceFeedbackPath
    start_time=(Get-Date -Format o)
    motion_child_exit_code=$null
    stop_restored=$false
    error=$null
}
$journalPath=Join-Path $run 'authorization_and_completion.json'
$journal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journalPath -Encoding utf8
$exitCode=1
try{
    # This explicit, scoped user resumption temporarily supersedes the previous
    # incident stop. Preserve it rather than deleting the incident history.
    $suspendedStop=Join-Path $run 'temporarily_suspended_stop.flag'
    Move-Item -LiteralPath $stop -Destination $suspendedStop
    $restorationSource=$suspendedStop
    if((Get-FileHash -LiteralPath $suspendedStop -Algorithm SHA256).Hash -ne $previousStopHash){throw 'Stop record changed during preparation; restore that record without moving the arm'}
    $runtime=(Get-Process -Id $PID).Path
    & $runtime -NoLogo -NoProfile -File $verifiedSource -Execute -ReferenceFeedbackPath $ReferenceFeedbackPath
    $exitCode=$LASTEXITCODE
    $journal['motion_child_exit_code']=$exitCode
}catch{
    $journal['error']=$_.Exception.Message
}finally{
    # Never overwrite a new operator stop created during the run.
    $handle=$null
    try{
        $contents=[IO.File]::ReadAllText($restorationSource)+"`nThe separately authorized single inward shoulder action has ended. Stop remains active for any further action.`n"
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($contents)
        $handle=[IO.File]::Open($stop,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $handle.Write($bytes,0,$bytes.Length)
        $handle.Flush()
    }catch{
        if(-not(Test-Path -LiteralPath $stop -PathType Leaf)){
            $journal['error']=([string]$journal['error']+'; stop restoration error: '+$_.Exception.Message)
        }
    }finally{
        if($null -ne $handle){$handle.Dispose()}
    }
    $journal['stop_restored']=Test-Path -LiteralPath $stop -PathType Leaf
    $journal['end_time']=Get-Date -Format o
    $journal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journalPath -Encoding utf8
}
$journal | ConvertTo-Json -Depth 5
if(-not $journal['stop_restored']){throw 'Motion ended but the software stop flag could not be restored'}
exit $exitCode
