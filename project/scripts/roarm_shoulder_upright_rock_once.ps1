param([switch]$Execute,[string]$ReferenceFeedbackPath)
$ErrorActionPreference='Stop'
$Port='COM15'
$ExpectedDevice='USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'
$Fields=@('b','s','e','t')
$Limits=@{b=@(-3.0,3.0);s=@(-1.5,1.5);e=@(-.7,3.05);t=@(1.15,5.12)}
$OffsetsDeg=@(2.0,5.0,0.0,-5.0,0.0)
$StageNames=@('direction_check_plus2','plus5','center_after_plus5','minus5','final_center')
# This name describes a near-zero ENCODER interval, not verified physical verticality.
# Stock mode-0 FK is not an independent measurement of reassembled geometry.
# Only T105 and T101 joint 2 are permitted. A T101 target can itself enable
# both shoulder servos. No individual servo, PID, limit, calibration, mode,
# home, reset or explicit torque-switch command is permitted.
# torS includes cached ID13 data: the 600 threshold is an additional host
# anomaly gate, not a torque measurement or a hardware overload protection.
# No support or new scene-clearance confirmation is asserted by this script.
# Any failure prevents subsequent targets, including all planned returns.
# Closing the host does not stop an active servo target. Cleanup sends nothing.
if(-not $Execute){
    [ordered]@{preview=$true;opens_serial=$false;port=$Port;device=$ExpectedDevice;allowed_commands=@(105,101);allowed_target_joints=@(2);maximum_target_attempts=5;center_offsets_deg=$OffsetsDeg;initial_encoder_shoulder_interval_deg=@(-5,5);actual_mechanical_zero_verified=$false;read_only_check_min_s=2;stage_observation_deadline_s=4;reply_deadline_s=.3;speed_steps_s=100;acc_100steps_s2=1;final_stability_min_s=1.5;all_axis_stability_peak_to_peak_deg=.2;global_shoulder_center_margin_deg=6.5;segment_margin_deg=1.5;reverse_motion_abort_deg=.35;inactive_max_drift_deg=1;minimum_signed_progress_fraction=.5;first_stage_minimum_progress_deg=1;target_error_rule='min(2 degrees, 0.4 * actual start-to-target span)';torS_absolute_abort_threshold=600;torS_is_torque_or_protection=$false;failure='Stop further host writes. No blind return or torque release; previous targets may remain active. Operator must cut 12V if the arm keeps driving or strains.';scope='One near-zero-encoder paired-shoulder diagnostic; conditional five-stage sequence, not resolution of earlier extended-arm failures'}|ConvertTo-Json -Depth 6
    exit 0
}
function Assert-Numeric($Object,[string[]]$Keys){
    if($Object -isnot [System.Collections.IDictionary]){throw 'Expected a numeric-field dictionary'}
    foreach($key in $Keys){
        if(-not $Object.Contains($key) -or $null -eq $Object[$key] -or $Object[$key] -is [string] -or $Object[$key] -is [bool] -or $Object[$key] -isnot [ValueType] -or -not [double]::IsFinite([double]$Object[$key])){throw "Invalid numeric feedback field: $key"}
    }
}
function Assert-ControllerText([string]$Text){
    if($Text -match '(?i)status\s*:\s*failed|Servo\s+ID[^\r\n]*failed|\brst\s*:|\bboot\s*:|ESP-ROM|Brownout detector|Guru Meditation'){throw 'Servo acquisition failure or controller restart; cached angles are not usable'}
}
function Parse-ControllerLine([string]$Line){
    Assert-ControllerText $Line
    try{$obj=$Line|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{return $null}
    if($obj -isnot [System.Collections.IDictionary]){return $null}
    if($obj['T'] -eq 1005 -and $obj['status'] -eq 0){throw 'Firmware T1005 status 0 reports servo acquisition failure'}
    return $obj
}
function Assert-ModeZero($Object){
    Assert-Numeric $Object @('b','s','e','t','x','y','z','torS')
    $s=[double]$Object['s'];$e=[double]$Object['e'];$b=[double]$Object['b']
    $l2=[math]::Sqrt(236.82*236.82+30*30);$l3=[math]::Sqrt(280.15*280.15+1.73*1.73);$t2=[math]::Atan2(30,236.82)
    $r=$l2*[math]::Sin($s+$t2)+$l3*[math]::Sin($s+$e);$z=$l2*[math]::Cos($s+$t2)+$l3*[math]::Cos($s+$e)
    if([math]::Abs($r*[math]::Cos($b)-[double]$Object['x']) -gt .5 -or [math]::Abs($r*[math]::Sin($b)-[double]$Object['y']) -gt .5 -or [math]::Abs($z-[double]$Object['z']) -gt .5){throw 'Feedback is inconsistent with stock mode-0 FK; this check does not verify physical zero'}
}
function Assert-LoadProxy($Object){
    Assert-Numeric $Object @('torS')
    if([math]::Abs([double]$Object['torS']) -ge 600){throw 'Absolute torS reached 600; stop further host writes. This is not measured torque or a hardware protection. Cut 12V if driving/strain persists.'}
}
function Assert-Limits($Angles){
    Assert-Numeric $Angles $Fields
    foreach($key in $Fields){if([double]$Angles[$key] -lt $Limits[$key][0] -or [double]$Angles[$key] -gt $Limits[$key][1]){throw "Angle outside conservative limits: $key"}}
}
function Assert-InitialFeedback($Angles){
    Assert-Limits $Angles
    if([math]::Abs([double]$Angles['s']*180/[math]::PI) -gt 5+1e-9){throw 'Initial shoulder encoder angle must be within [-5,+5] degrees; physical upright alignment is not inferred'}
}
function Copy-Angles($Object){$copy=[ordered]@{};foreach($key in $Fields){$copy[$key]=[double]$Object[$key]};return $copy}
function Get-EnvelopeViolation($Angles,$Center,$StartAngles,[double]$GoalShoulderRad,[bool]$Moving){
    if($null -eq $Center){return $null}
    foreach($key in @('b','e','t')){
        if([math]::Abs(([double]$Angles[$key]-[double]$Center[$key])*180/[math]::PI) -gt 1+1e-9){return "Inactive $key drift exceeds 1 degree from this run's measured center"}
        if($null -ne $StartAngles -and [math]::Abs(([double]$Angles[$key]-[double]$StartAngles[$key])*180/[math]::PI) -gt 1+1e-9){return "Inactive $key drift exceeds 1 degree from actual stage start"}
    }
    if([math]::Abs(([double]$Angles['s']-[double]$Center['s'])*180/[math]::PI) -gt 6.5+1e-9){return 'Shoulder exceeded the measured-center +/-6.5-degree envelope'}
    if($Moving){
        if($null -eq $StartAngles -or -not [double]::IsFinite($GoalShoulderRad)){return 'Motion segment is undefined'}
        $start=[double]$StartAngles['s'];$angle=[double]$Angles['s'];$padding=1.5*[math]::PI/180
        if($angle -lt [math]::Min($start,$GoalShoulderRad)-$padding-1e-12 -or $angle -gt [math]::Max($start,$GoalShoulderRad)+$padding+1e-12){return 'Shoulder exceeded actual-start-to-target segment plus 1.5 degrees'}
        $direction=[math]::Sign($GoalShoulderRad-$start)
        if($direction*($angle-$start)*180/[math]::PI -lt -.35-1e-9){return 'Shoulder reversed more than 0.35 degree from actual stage start'}
    }else{
        if([math]::Abs(([double]$Angles['s']-[double]$Center['s'])*180/[math]::PI) -gt 1+1e-9){return 'Read-only shoulder drift exceeds 1 degree'}
    }
    return $null
}
function Get-StabilityWindow($Frames,[double]$Now){
    $startIndex=-1
    for($j=$Frames.Count-1;$j -ge 0;$j--){if([double]$Frames[$j]['elapsed_s'] -le $Now-1.5+1e-9){$startIndex=$j;break}}
    $stats=[ordered]@{qualified=$false;span_s=0.0;count=0;start_index=$startIndex;peak_to_peak_deg=[ordered]@{};mean_angles_rad=[ordered]@{}}
    if($startIndex -lt 0){return $stats}
    $stats['span_s']=$Now-[double]$Frames[$startIndex]['elapsed_s'];$stats['count']=$Frames.Count-$startIndex
    $stats['qualified']=($stats['span_s'] -ge 1.5-1e-9 -and $stats['count'] -ge 4)
    foreach($key in $Fields){
        $values=@(for($j=$startIndex;$j -lt $Frames.Count;$j++){[double]$Frames[$j]['angles_rad'][$key]})
        $m=$values|Measure-Object -Minimum -Maximum -Average
        $stats['peak_to_peak_deg'][$key]=($m.Maximum-$m.Minimum)*180/[math]::PI;$stats['mean_angles_rad'][$key]=[double]$m.Average
        if($stats['peak_to_peak_deg'][$key] -gt .2+1e-9){$stats['qualified']=$false}
    }
    return $stats
}
function Get-StageAssessment($StartAngles,$Goal,$Center,$Frames,[double]$Now,[double]$Begin,[bool]$ReadOnly,[bool]$DirectionCheck){
    $sample=$Frames[-1]['angles_rad'];$window=Get-StabilityWindow $Frames $Now
    $span=([double]$Goal['s']-[double]$StartAngles['s'])*180/[math]::PI
    $signed=[math]::Sign($span)*([double]$sample['s']-[double]$StartAngles['s'])*180/[math]::PI
    $error=([double]$sample['s']-[double]$Goal['s'])*180/[math]::PI
    $tolerance=[math]::Min(2.0,.4*[math]::Abs($span));$minimumProgress=.5*[math]::Abs($span)
    if($DirectionCheck){$minimumProgress=[math]::Max(1.0,$minimumProgress)}
    $violation=Get-EnvelopeViolation $sample $Center $StartAngles ([double]$Goal['s']) (-not $ReadOnly)
    $movement=($ReadOnly -or ([math]::Abs($span) -gt 1e-9 -and $signed -gt 0 -and $signed+1e-9 -ge $minimumProgress))
    $targetOk=($ReadOnly -or [math]::Abs($error) -le $tolerance+1e-9)
    # Every sample in the final observed stable window must be close to the target.
    if(-not $ReadOnly -and $window['start_index'] -ge 0){
        for($j=$window['start_index'];$j -lt $Frames.Count;$j++){
            if([math]::Abs(([double]$Frames[$j]['angles_rad']['s']-[double]$Goal['s'])*180/[math]::PI) -gt $tolerance+1e-9){$targetOk=$false}
        }
    }
    $duration=$Now-$Begin;$minDuration=if($ReadOnly){2.0}else{1.5}
    $maxDuration=if($ReadOnly){3.0}else{4.0}
    return [ordered]@{duration_s=$duration;stability_window=$window;bounds_violation=$violation;commanded_span_deg=[math]::Abs($span);signed_displacement_deg=$signed;minimum_signed_progress_deg=$minimumProgress;movement_verified=$movement;target_error_deg=$error;allowed_target_error_deg=$tolerance;target_within_tolerance=$targetOk;passed=(-not $violation -and $duration -ge $minDuration -and $duration -le $maxDuration+1e-9 -and $window['qualified'] -and $movement -and $targetOk)}
}

if([string]::IsNullOrWhiteSpace($ReferenceFeedbackPath)){throw 'An independent recent read-only reference summary is required'}
if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Stop flag is present; only the reviewed one-run launcher may supersede it for this explicit scope'}
$referenceInfo=Get-Item -LiteralPath $ReferenceFeedbackPath
$referenceAge=((Get-Date)-$referenceInfo.LastWriteTime).TotalSeconds
if($referenceAge -lt -5 -or $referenceAge -gt 600){throw 'Reference must be at most 10 minutes old'}
$reference=Get-Content -Raw -LiteralPath $ReferenceFeedbackPath|ConvertFrom-Json -AsHashtable
if($reference['port'] -ne $Port -or $reference['device'] -ne $ExpectedDevice -or $reference['motion_commands_sent'] -ne 0 -or $null -ne $reference['error'] -or $reference['feedback'].Count -lt 4){throw 'Invalid reference identity or acquisition summary'}
$referenceRawPath=Join-Path $referenceInfo.DirectoryName 'serial.jsonl'
if(-not(Test-Path -LiteralPath $referenceRawPath -PathType Leaf)){throw 'Reference serial.jsonl is required; summary alone cannot exclude cached feedback'}
$referenceQueryCount=0;$referenceRawFeedback=[Collections.Generic.List[object]]::new()
foreach($recordLine in (Get-Content -LiteralPath $referenceRawPath)){
    $record=$recordLine|ConvertFrom-Json -AsHashtable
    if(-not $record.Contains('raw') -or $record['raw'] -isnot [string]){throw 'Reference raw schema is invalid'}
    Assert-ControllerText ([string]$record['raw'])
    foreach($line in ([string]$record['raw'] -split "`n")){
        $packet=Parse-ControllerLine $line
        if($record['kind'] -eq 'tx_attempt' -and $null -ne $packet){
            if($packet['T'] -notin @(105,602)){throw 'Reference contains a non-read-only command'}
            if($packet['T'] -eq 105){$referenceQueryCount++}
        }
        if($record['kind'] -eq 'rx' -and $null -ne $packet -and $packet['T'] -eq 1051){Assert-ModeZero $packet;Assert-LoadProxy $packet;$referenceRawFeedback.Add($packet)}
    }
}
if($referenceQueryCount -lt 4 -or $referenceRawFeedback.Count -lt 4){throw 'Reference requires four raw T105 requests and usable replies'}
$referenceSamples=@($reference['feedback']|Select-Object -Last 4)
foreach($sample in $referenceSamples){Assert-ModeZero $sample;Assert-LoadProxy $sample;Assert-InitialFeedback $sample}
foreach($key in $Fields){
    $range=$referenceSamples|ForEach-Object{[double]$_[$key]}|Measure-Object -Minimum -Maximum
    if($range.Maximum-$range.Minimum -gt .008){throw 'Last four reference samples are not stable'}
    if([math]::Abs([double]$referenceSamples[-1][$key]-[double]$referenceRawFeedback[-1][$key]) -gt 1e-9){throw 'Reference summary and last raw frame disagree'}
}
$device=@(Get-CimInstance Win32_SerialPort|Where-Object DeviceID -eq $Port)
if($device.Count -ne 1 -or $device[0].PNPDeviceID -ne $ExpectedDevice){throw 'Exact commissioned COM15 USB identity was not found'}
$outDir=Join-Path 'C:\new\results\hardware_control' ('shoulder_upright_rock_once_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir|Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
Copy-Item -LiteralPath $ReferenceFeedbackPath -Destination (Join-Path $outDir 'reference_feedback.json')
Copy-Item -LiteralPath $referenceRawPath -Destination (Join-Path $outDir 'reference_serial.jsonl')
$sourceHash=(Get-FileHash -LiteralPath (Join-Path $outDir 'executed_script.ps1') -Algorithm SHA256).Hash
$logPath=Join-Path $outDir 'serial.jsonl';$clock=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None;$serial.DtrEnable=$false;$serial.RtsEnable=$false
$serial.ReadTimeout=100;$serial.WriteTimeout=300;$serial.NewLine="`n"
$pending='';$origin=$null;$center=$null;$last=$null;$lastValidatedElapsed=$null;$failure=$null
$targetAttempts=0;$targetsSent=0;$queriesSent=0;$activeStage='startup';$readOnlyStablePassed=$false
$motionStageActive=$false;$stageStartAngles=$null;$stageGoalShoulderRad=[double]::NaN;$stageWriteStart=$null
$lastReceivedFeedback=$null;$lastReceivedElapsed=$null;$lastReceivedModeValidated=$false;$lastReceivedBoundsValidated=$false
$stageResults=[Collections.Generic.List[object]]::new()
function Record([string]$Kind,$Data){[ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;kind=$Kind;data=$Data}|ConvertTo-Json -Depth 12 -Compress|Add-Content -LiteralPath $logPath -Encoding utf8}
function Assert-StopFlag{if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Operator stop flag present; no further host writes'}}
function Check-Unsolicited{
    Assert-StopFlag
    if($serial.BytesToRead -gt 0){$script:pending+=$serial.ReadExisting()}
    if($script:pending.Length -eq 0){return}
    Record 'prequery_bytes' $script:pending;Assert-ControllerText $script:pending
    if(-not $script:pending.EndsWith("`n")){throw 'Incomplete unsolicited frame; residual bytes cannot be safely associated'}
    foreach($line in ($script:pending -split "`n")){$obj=Parse-ControllerLine $line;if($null -ne $obj -and $obj['T'] -eq 1051){throw 'Unsolicited or delayed T1051; no request identifier is available'}}
    $script:pending=''
}
function Send-Packet($Packet){
    Assert-StopFlag
    if($Packet['T'] -notin @(105,101)){throw 'Command outside T105/T101 allowlist'}
    if($Packet['T'] -eq 101){
        if($Packet['joint'] -ne 2 -or $Packet['spd'] -ne 100 -or $Packet['acc'] -ne 1){throw 'Only fixed-speed paired shoulder joint 2 targets are permitted'}
        Assert-Numeric $Packet @('rad')
        if($script:targetAttempts -ge 5 -or -not $script:readOnlyStablePassed -or $null -eq $script:center){throw 'Motion prerequisite or maximum target-attempt guard failed'}
        $expected=[double]$script:center['s']+$OffsetsDeg[$script:targetAttempts]*[math]::PI/180
        if([math]::Abs([double]$Packet['rad']-$expected) -gt 1e-10 -or [math]::Abs([double]$Packet['rad']-$script:stageGoalShoulderRad) -gt 1e-10){throw 'Target differs from the predefined measured-center sequence'}
        if($null -eq $script:lastValidatedElapsed -or $clock.Elapsed.TotalSeconds-$script:lastValidatedElapsed -gt .3){throw 'Latest validated host reply is older than 300 ms; no target sent'}
        Assert-LoadProxy $script:last
        Assert-Limits $script:last
        $v=Get-EnvelopeViolation $script:last $script:center $script:stageStartAngles $script:stageGoalShoulderRad $true
        if($v){throw $v}
    }
    $text=$Packet|ConvertTo-Json -Compress;Record 'tx_attempt' @{stage=$script:activeStage;packet=$text}
    Assert-StopFlag
    if($Packet['T'] -eq 101){$script:targetAttempts++;$script:motionStageActive=$true;$script:stageWriteStart=$clock.Elapsed.TotalSeconds}
    $serial.WriteLine($text)
    if($Packet['T'] -eq 101){$script:targetsSent++}else{$script:queriesSent++}
}
function Get-Sample([double]$OuterDeadline=[double]::PositiveInfinity){
    Check-Unsolicited
    $requestStart=$clock.Elapsed.TotalSeconds
    if($requestStart -ge $OuterDeadline){throw 'Stage observation deadline reached; no further query or target'}
    $deadline=[math]::Min($requestStart+.3,$OuterDeadline)
    Send-Packet ([ordered]@{T=105})
    $reply=$null
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        Assert-StopFlag
        if($serial.BytesToRead -gt 0){$script:pending+=$serial.ReadExisting()}
        if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
        Assert-ControllerText $script:pending
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n");$line=$script:pending.Substring(0,$idx).TrimEnd("`r");$script:pending=$script:pending.Substring($idx+1)
            Record 'rx' @{stage=$script:activeStage;raw=$line}
            $obj=Parse-ControllerLine $line
            if($null -ne $obj -and $obj['T'] -eq 1051){
                $script:lastReceivedFeedback=$obj;$script:lastReceivedElapsed=$clock.Elapsed.TotalSeconds
                $script:lastReceivedModeValidated=$false;$script:lastReceivedBoundsValidated=$false
                if($null -ne $reply){throw 'Multiple T1051 replies to one query; association ambiguous'}
                Assert-ModeZero $obj;$script:lastReceivedModeValidated=$true
                Assert-LoadProxy $obj;Assert-Limits $obj
                if(-not $script:motionStageActive){Assert-InitialFeedback $obj}
                $v=Get-EnvelopeViolation $obj $script:center $script:stageStartAngles $script:stageGoalShoulderRad $script:motionStageActive
                if($v){throw $v}
                $script:lastReceivedBoundsValidated=$true;$reply=$obj
            }
        }
        if($null -ne $reply){
            if($clock.Elapsed.TotalSeconds -gt $deadline){throw 'Reply exceeded 300-ms or stage deadline; no further target'}
            if($script:pending.Length){throw 'Trailing incomplete frame; cannot exclude firmware failure'}
            $script:last=$reply;$script:lastValidatedElapsed=$clock.Elapsed.TotalSeconds;return $reply
        }
        Start-Sleep -Milliseconds 10
    }
    throw 'Feedback timeout at 300-ms or stage deadline; no blind return'
}
function Observe-Stage([string]$Name,$StartAngles,$Goal,[bool]$ReadOnly,[bool]$DirectionCheck=$false){
    $script:activeStage=$Name;$script:stageStartAngles=Copy-Angles $StartAngles;$script:stageGoalShoulderRad=[double]$Goal['s']
    $frames=[Collections.Generic.List[object]]::new()
    $result=[ordered]@{name=$Name;read_only=$ReadOnly;direction_check=$DirectionCheck;start_angles_rad=Copy-Angles $StartAngles;target_angles_rad=Copy-Angles $Goal;observations=$frames;passed=$false;error=$null;assessment=$null;end_feedback=$null;start_elapsed_s=$clock.Elapsed.TotalSeconds}
    $script:stageResults.Add($result)
    try{
        Check-Unsolicited
        if(-not $ReadOnly){Send-Packet ([ordered]@{T=101;joint=2;rad=[double]$Goal['s'];spd=100;acc=1});$begin=$script:stageWriteStart;$deadline=$begin+4.0}
        else{$begin=$clock.Elapsed.TotalSeconds;$deadline=$begin+3.0}
        $result['start_elapsed_s']=$begin
        while($clock.Elapsed.TotalSeconds -lt $deadline){
            Start-Sleep -Milliseconds 100
            if($clock.Elapsed.TotalSeconds -ge $deadline){break}
            $sample=Get-Sample $deadline;$now=$clock.Elapsed.TotalSeconds
            $frames.Add([ordered]@{elapsed_s=$now;angles_rad=Copy-Angles $sample;torS=[double]$sample['torS']})
            $result['end_feedback']=$sample
            $assessment=Get-StageAssessment $StartAngles $Goal $script:center $frames $now $begin $ReadOnly $DirectionCheck
            $result['assessment']=$assessment
            if($assessment['bounds_violation']){throw $assessment['bounds_violation']}
            if($assessment['passed']){$result['passed']=$true;break}
        }
        if(-not $result['passed']){throw 'Stage failed its fixed deadline, direction, target-error or final 1.5-second stability criteria; no next target or automatic return'}
        Record 'stage_passed' $result
    }catch{$result['error']=$_.Exception.Message;try{Record 'stage_failed' $result}catch{};throw}
}
try{
    Assert-StopFlag;$serial.Open();Record 'open' '115200 8N1; DTR/RTS false; no reset requested'
    Start-Sleep -Milliseconds 500
    $activeStage='preflight';$fresh=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 4;$i++){$fresh.Add((Get-Sample));Start-Sleep -Milliseconds 100}
    foreach($key in $Fields){
        $range=$fresh|ForEach-Object{[double]$_[$key]}|Measure-Object -Minimum -Maximum
        if($range.Maximum-$range.Minimum -gt .008){throw 'Four fresh preflight replies are not stable'}
        foreach($sample in $fresh){if([math]::Abs([double]$sample[$key]-[double]$referenceSamples[-1][$key]) -gt .03){throw "Pose differs from the independent reference: $key"}}
    }
    $origin=Copy-Angles $fresh[-1];Assert-InitialFeedback $origin;$center=Copy-Angles $origin
    Observe-Stage 'read_only_current_stability' $origin $origin $true
    $readOnlyStablePassed=$true
    # The center is a new validated measurement, never an old command target.
    $center=Copy-Angles $last;Assert-InitialFeedback $center
    foreach($offset in $OffsetsDeg){$candidate=Copy-Angles $center;$candidate['s']+=$offset*[math]::PI/180;Assert-Limits $candidate}
    Record 'plan' @{measured_center=$center;offsets_deg=$OffsetsDeg;maximum_target_attempts=5;encoder_interval_only=$true;physical_upright_verified=$false;initial_read_only_min_s=2;stage_deadline_s=4;final_stability_s=1.5;stability_peak_to_peak_deg=.2;reverse_abort_deg=.35;global_center_bound_deg=6.5;segment_padding_deg=1.5;inactive_drift_deg=1;minimum_progress_fraction=.5;direction_check_minimum_progress_deg=1;target_error_rule='min(2,0.4*actual span) degrees';torS_abort_absolute=600;torS_is_torque_or_protection=$false;servo13_readback_available=$false;independent_support_asserted=$false;current_scene_clearance_independently_confirmed=$false;previous_targets_imported=$false;prior_extended_arm_failure_resolved=$false;source_sha256=$sourceHash}
    for($k=0;$k -lt $OffsetsDeg.Count;$k++){
        if($k -gt 0){
            $previousEnd=Copy-Angles $last;$freshStart=Get-Sample
            foreach($key in $Fields){if([math]::Abs(([double]$freshStart[$key]-[double]$previousEnd[$key])*180/[math]::PI) -gt .2+1e-9){throw 'Pose drifted after the passed stability window; no next target'} }
        }
        $actualStart=Copy-Angles $last;$goal=Copy-Angles $center;$goal['s']+=$OffsetsDeg[$k]*[math]::PI/180
        Observe-Stage $StageNames[$k] $actualStart $goal $false ($k -eq 0)
    }
    $activeStage='complete'
}catch{$failure=$_.Exception.Message;try{Record 'failure' $failure}catch{}}
finally{
    if($failure){Write-Warning 'Host test stopped; the previous servo target may keep driving. No automatic return, brake or torque release was sent. Cut the 12V supply if motion/strain persists.' -WarningAction Continue}
    if($pending.Length){try{Record 'unparsed_pending_on_exit' $pending}catch{}}
    try{if($serial.IsOpen){$serial.Close()}}catch{if(-not $failure){$failure='Serial close failed: '+$_.Exception.Message}}finally{$serial.Dispose()}
    try{Record 'closed' 'Zero hardware writes in cleanup; host close does not cancel a servo target'}catch{if(-not $failure){$failure='Final log failed: '+$_.Exception.Message}}
}
$passed=($stageResults.Count -eq 6 -and @($stageResults|Where-Object{-not $_['passed']}).Count -eq 0 -and -not $failure)
$result=[ordered]@{port=$Port;device=$ExpectedDevice;output_dir=$outDir;source_sha256=$sourceHash;reference_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_feedback.json') -Algorithm SHA256).Hash;reference_raw_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_serial.jsonl') -Algorithm SHA256).Hash;target_attempts=$targetAttempts;targets_sent=$targetsSent;queries_sent=$queriesSent;all_stages_passed=$passed;read_only_stability_passed=$readOnlyStablePassed;origin=$origin;measured_center=$center;stages=$stageResults;last_feedback=$last;last_validated_feedback=$last;last_validated_elapsed_s=$lastValidatedElapsed;last_received_feedback=$lastReceivedFeedback;last_received_elapsed_s=$lastReceivedElapsed;last_received_mode_validated=$lastReceivedModeValidated;last_received_bounds_validated=$lastReceivedBoundsValidated;last_received_semantics='Most recent decoded 1051, possibly rejected; not a validated or independently fresh sample';error=$failure;automatic_torque_release=$false;only_paired_shoulder_joint2_targets=$true;center_offsets_deg=$OffsetsDeg;physical_upright_verified=$false;mechanical_zero_verified=$false;servo13_individually_visible=$false;shoulder_follower_alignment_verified=$false;torS_is_measured_torque=$false;torS_is_hardware_protection=$false;independent_support_asserted=$false;prior_extended_arm_failure_resolved=$false;scope='One conditional near-zero-encoder shoulder diagnostic, direction precheck then small rocking; no claim that reassembly or extended-load operation is qualified';end_state='Previous device targets may remain active; closing serial does not cancel them. Operator power intervention may be needed.'}
$result|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result|ConvertTo-Json -Depth 16
if($failure -or -not $passed){exit 1}
