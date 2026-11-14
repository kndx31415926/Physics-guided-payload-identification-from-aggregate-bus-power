param([switch]$Execute,[string]$ExpectedSourceSha256,[string]$ReferenceFeedbackPath)
$ErrorActionPreference='Stop'
$source='C:\new\scripts\roarm_shoulder_upright_rock_once.ps1'
$stop='C:\new\hardware_stop.flag'
$scope='One near-zero-encoder shoulder diagnostic: fresh measured center within +/-5 deg, conditional targets center+2, center+5, center, center-5, center; at most five T101 joint2 targets, spd100 acc1. Every stage must pass direction, target-error and stability gates before another target. No other-axis, torque-switch, reset, home, calibration, PID or limit write.'
if(-not $Execute){
    [ordered]@{preview=$true;opens_serial=$false;changes_stop_flag=$false;source=$source;scope=$scope;execution_requires='Reviewed exact motion-source SHA256 and new read-only reference; archives existing stop, invokes only the verified snapshot, then restores a stop with CreateNew without replacing a newer operator stop'}|ConvertTo-Json -Depth 4
    exit 0
}
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Use the reviewed PowerShell 7 runtime'}
if($ExpectedSourceSha256 -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Exact independently reviewed motion source hash is required'}
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $ExpectedSourceSha256){throw 'Motion source changed after review; stop flag untouched'}
if(-not(Test-Path -LiteralPath $ReferenceFeedbackPath -PathType Leaf)){throw 'Reference summary missing'}
$referenceFile=Get-Item -LiteralPath $ReferenceFeedbackPath
$referenceRaw=Join-Path $referenceFile.DirectoryName 'serial.jsonl'
if(-not(Test-Path -LiteralPath $referenceRaw -PathType Leaf)){throw 'Reference raw log missing'}
if(-not(Test-Path -LiteralPath $stop -PathType Leaf)){throw 'Prior stop record is absent; no action taken'}
$run=Join-Path 'C:\new\results\hardware_control' ('authorized_upright_rock_once_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
$resolvedRun=[IO.Path]::GetFullPath($run)
if(-not $resolvedRun.StartsWith('C:\new\results\hardware_control\',[StringComparison]::OrdinalIgnoreCase)){throw 'Launcher output escaped the intended workspace'}
if([IO.Path]::GetFullPath($stop) -ne 'C:\new\hardware_stop.flag'){throw 'Unexpected stop-file target'}
New-Item -ItemType Directory -Path $run|Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $run 'executed_launcher.ps1')
$verifiedSource=Join-Path $run 'reviewed_motion_script.ps1'
Copy-Item -LiteralPath $source -Destination $verifiedSource
if((Get-FileHash -LiteralPath $verifiedSource -Algorithm SHA256).Hash -ne $ExpectedSourceSha256){throw 'Motion snapshot differs from reviewed hash; stop flag untouched'}
$referenceDir=Join-Path $run 'independent_reference';New-Item -ItemType Directory -Path $referenceDir|Out-Null
$verifiedReference=Join-Path $referenceDir 'summary.json'
Copy-Item -LiteralPath $ReferenceFeedbackPath -Destination $verifiedReference
Copy-Item -LiteralPath $referenceRaw -Destination (Join-Path $referenceDir 'serial.jsonl')
$archivedStop=Join-Path $run 'previous_hardware_stop.flag'
Copy-Item -LiteralPath $stop -Destination $archivedStop
$previousStopHash=(Get-FileHash -LiteralPath $archivedStop -Algorithm SHA256).Hash
$restorationSource=$archivedStop
$journal=[ordered]@{
    user_authorization='Supervising thread records user-confirmed power cycle and request for movement about the present shoulder angle; this launcher implements only the reviewed small diagnostic scope.'
    scope=$scope;source_sha256=$ExpectedSourceSha256
    launcher_sha256=(Get-FileHash -LiteralPath (Join-Path $run 'executed_launcher.ps1') -Algorithm SHA256).Hash
    reference_original=$ReferenceFeedbackPath;reference_snapshot=$verifiedReference
    reference_sha256=(Get-FileHash -LiteralPath $verifiedReference -Algorithm SHA256).Hash
    reference_raw_sha256=(Get-FileHash -LiteralPath (Join-Path $referenceDir 'serial.jsonl') -Algorithm SHA256).Hash
    previous_stop_sha256=$previousStopHash;start_time=(Get-Date -Format o)
    physical_upright_verified=$false;mechanical_zero_verified=$false;independent_support_asserted=$false
    previous_extended_arm_failure_resolved=$false;current_scene_clearance_independently_confirmed=$false
    motion_child_exit_code=$null;stop_restored=$false;newer_operator_stop_preserved=$false;error=$null
}
$journalPath=Join-Path $run 'authorization_and_completion.json'
$journal|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $journalPath -Encoding utf8
$exitCode=1
try{
    # Only -Execute reaches this scoped suspension; old stop contents remain archived.
    $suspendedStop=Join-Path $run 'temporarily_suspended_stop.flag'
    if(-not [IO.Path]::GetFullPath($suspendedStop).StartsWith($resolvedRun+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid suspension destination'}
    Move-Item -LiteralPath $stop -Destination $suspendedStop
    $restorationSource=$suspendedStop
    if((Get-FileHash -LiteralPath $suspendedStop -Algorithm SHA256).Hash -ne $previousStopHash){throw 'Stop record changed during preparation; restore it without commanding the arm'}
    $runtime=(Get-Process -Id $PID).Path
    & $runtime -NoLogo -NoProfile -File $verifiedSource -Execute -ReferenceFeedbackPath $verifiedReference
    $exitCode=$LASTEXITCODE;$journal['motion_child_exit_code']=$exitCode
}catch{$journal['error']=$_.Exception.Message;$exitCode=1}
finally{
    # Never replace a new stop written while this separately authorized scope ran.
    $handle=$null
    try{
        $oldBytes=[IO.File]::ReadAllBytes($restorationSource)
        $note=[Text.UTF8Encoding]::new($false).GetBytes("`nThe separately authorized near-zero shoulder diagnostic has ended. Stop remains active for any further action. Host stop does not cancel servo targets.`n")
        $bytes=[byte[]]($oldBytes+$note)
        $handle=[IO.File]::Open($stop,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $handle.Write($bytes,0,$bytes.Length);$handle.Flush()
    }catch{
        if(Test-Path -LiteralPath $stop -PathType Leaf){$journal['newer_operator_stop_preserved']=$true}
        else{$journal['error']=([string]$journal['error']+'; stop restoration error: '+$_.Exception.Message);$exitCode=1}
    }finally{if($null -ne $handle){$handle.Dispose()}}
    $journal['stop_restored']=Test-Path -LiteralPath $stop -PathType Leaf
    $journal['end_time']=Get-Date -Format o
    $journal|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $journalPath -Encoding utf8
}
$journal|ConvertTo-Json -Depth 6
if(-not $journal['stop_restored']){throw 'Motion scope ended but the stop flag could not be restored'}
exit $exitCode
