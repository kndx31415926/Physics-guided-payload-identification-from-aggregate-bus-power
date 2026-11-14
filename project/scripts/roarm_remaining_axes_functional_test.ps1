param([switch]$Execute,[string]$ReferenceFeedbackPath)
$ErrorActionPreference='Stop'
$Port='COM15'
$ExpectedDevice='USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'
$Fields=@('b','s','e','t')
$Limits=@{b=@(-3.0,3.0);s=@(-1.5,1.5);e=@(-.7,3.05);t=@(1.15,5.12)}
$Steps=@(@{name='elbow';field='e';joint=3;delta_deg=-5.0},@{name='empty_gripper';field='t';joint=4;delta_deg=-15.0})
# Remaining-axes diagnostic: read-only baseline, then elbow and empty gripper only.
# No base or shoulder position target is sent; their existing device targets are not replaced.
# Fixed criteria distinguish a bounded settled offset from continuing drift; not adjusted during a run.
# Stock feedback cannot independently establish shoulder follower alignment or applied holding torque.
# User has not supplied an independent support. No support is asserted here.
# No T210, home, mode, PID, calibration or persistent-setting command is allowed.
# Finally performs zero hardware writes. Failure does not automatically release torque.
if(-not $Execute){
    [ordered]@{preview=$true;opens_serial=$false;port=$Port;device=$ExpectedDevice;allowed_commands=@(105,101);allowed_target_joints=@(3,4);maximum_position_target_attempts=4;initial_read_only_check='At least 2 seconds of T105 only; no position or torque-switch write';excursions=$Steps;movement='Only single-joint T101, spd 100, acc 1; each leg 4 to 8 seconds; return after each passed excursion';functional_criteria='Final >=1.5 s all-axis peak-to-peak <=0.2 deg. Inactive leg axes drift <=1 deg from actual start and stay <=3 deg from this run new measured reference. Active leg moves in correct direction >=50% of actual-start-to-target span and remains in the segment plus 2 deg margin.';diagnostic_only='Final target error within 2 deg and return within 1 deg of the new measured baseline are recorded, not pass/fail gates.';requires='New successful raw-error-checked four-frame reference, exact USB identity, new preflight feedback';failure='Stop new writes, close host serial port; previous device targets may remain active and operator takeover is required';limits_rad=$Limits;scope='Elbow and empty gripper functional diagnostic only; no new base or shoulder targets, no claim of shoulder-follower alignment'}|ConvertTo-Json -Depth 6
    exit 0
}
function Assert-Numeric($Object,[string[]]$Keys){
    foreach($key in $Keys){
        if(-not $Object.Contains($key) -or $null -eq $Object[$key] -or $Object[$key] -is [string] -or $Object[$key] -is [bool] -or $Object[$key] -isnot [ValueType] -or -not [double]::IsFinite([double]$Object[$key])){throw "Invalid numeric feedback field: $key"}
    }
}
function Assert-ControllerText([string]$Text){
    if($Text -match '(?i)status\s*:\s*failed|Servo\s+ID[^\r\n]*failed|\brst\s*:|\bboot\s*:|ESP-ROM|Brownout detector|Guru Meditation'){throw 'Servo acquisition failure or controller restart in raw serial text; cached angles are not usable'}
}
function Parse-ControllerLine([string]$Line){
    Assert-ControllerText $Line
    $obj=$null
    try{$obj=$Line|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{return $null}
    if($obj -isnot [System.Collections.IDictionary]){return $null}
    if($obj['T'] -eq 1005 -and $obj['status'] -eq 0){throw 'Firmware T1005 status 0 reports servo acquisition failure; no further writes'}
    return $obj
}
function Assert-ModeZero($Object){
    Assert-Numeric $Object @('b','s','e','t','x','y','z')
    $s=[double]$Object['s'];$e=[double]$Object['e'];$b=[double]$Object['b']
    $l2=[math]::Sqrt(236.82*236.82+30*30);$l3=[math]::Sqrt(280.15*280.15+1.73*1.73);$t2=[math]::Atan2(30,236.82)
    $r=$l2*[math]::Sin($s+$t2)+$l3*[math]::Sin($s+$e)
    $z=$l2*[math]::Cos($s+$t2)+$l3*[math]::Cos($s+$e)
    if([math]::Abs($r*[math]::Cos($b)-[double]$Object['x']) -gt .5 -or [math]::Abs($r*[math]::Sin($b)-[double]$Object['y']) -gt .5 -or [math]::Abs($z-[double]$Object['z']) -gt .5){throw 'Feedback does not match audited mode-0 empty-gripper mapping'}
}
function Assert-Limits($Angles){
    Assert-Numeric $Angles $Fields
    foreach($key in $Fields){if([double]$Angles[$key] -lt $Limits[$key][0] -or [double]$Angles[$key] -gt $Limits[$key][1]){throw "Angle outside conservative limits: $key"}}
}
function Copy-Angles($Object){$copy=[ordered]@{};foreach($key in $Fields){$copy[$key]=[double]$Object[$key]};return $copy}
if([string]::IsNullOrWhiteSpace($ReferenceFeedbackPath)){throw 'An independent recent read-only reference summary is required'}
$referenceInfo=Get-Item -LiteralPath $ReferenceFeedbackPath
$referenceAge=((Get-Date)-$referenceInfo.LastWriteTime).TotalSeconds
if($referenceAge -lt -5 -or $referenceAge -gt 600){throw 'Reference must be at most 10 minutes old'}
$reference=Get-Content -Raw -LiteralPath $ReferenceFeedbackPath|ConvertFrom-Json -AsHashtable
if($reference['port'] -ne $Port -or $reference['device'] -ne $ExpectedDevice -or $reference['motion_commands_sent'] -ne 0 -or $null -ne $reference['error'] -or $reference['feedback'].Count -lt 4){throw 'Invalid reference identity or acquisition summary'}
$referenceRawPath=Join-Path $referenceInfo.DirectoryName 'serial.jsonl'
if(-not(Test-Path -LiteralPath $referenceRawPath -PathType Leaf)){throw 'Reference raw serial.jsonl is mandatory; summary alone can contain cached feedback'}
$referenceRaw=Get-Content -LiteralPath $referenceRawPath
$referenceQueryCount=0;$referenceRawFeedback=[Collections.Generic.List[object]]::new()
foreach($recordLine in $referenceRaw){
    $record=$recordLine|ConvertFrom-Json -AsHashtable
    if(-not $record.Contains('raw') -or $record['raw'] -isnot [string]){throw 'Reference raw log schema invalid'}
    $raw=[string]$record['raw'];Assert-ControllerText $raw
    foreach($rawLine in ($raw -split "`n")){
        $packet=Parse-ControllerLine $rawLine
        if($record['kind'] -eq 'tx_attempt' -and $null -ne $packet){
            if($packet['T'] -notin @(105,602)){throw 'Reference log includes a command other than read-only T105/T602'}
            if($packet['T'] -eq 105){$referenceQueryCount++}
        }
        if($record['kind'] -eq 'rx' -and $null -ne $packet -and $packet['T'] -eq 1051){Assert-ModeZero $packet;$referenceRawFeedback.Add($packet)}
    }
}
if($referenceQueryCount -lt 4 -or $referenceRawFeedback.Count -lt 4){throw 'Reference needs at least four raw T105 requests and four usable replies'}
$referenceSamples=@($reference['feedback']|Select-Object -Last 4)
foreach($sample in $referenceSamples){Assert-ModeZero $sample;Assert-Limits $sample}
foreach($key in $Fields){
    $range=$referenceSamples|ForEach-Object{[double]$_[$key]}|Measure-Object -Minimum -Maximum
    if($range.Maximum-$range.Minimum -gt .008){throw 'Last four independent reference frames are not stable'}
    if([math]::Abs([double]$referenceSamples[-1][$key]-[double]$referenceRawFeedback[-1][$key]) -gt .000000001){throw 'Reference summary and last raw frame disagree'}
}
$device=@(Get-CimInstance Win32_SerialPort|Where-Object DeviceID -eq $Port)
if($device.Count -ne 1 -or $device[0].PNPDeviceID -ne $ExpectedDevice){throw 'Exact commissioned COM15 USB identity was not found'}
$outDir=Join-Path 'C:\new\results\hardware_control' ('remaining_axes_functional_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir|Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
Copy-Item -LiteralPath $ReferenceFeedbackPath -Destination (Join-Path $outDir 'reference_feedback.json')
Copy-Item -LiteralPath $referenceRawPath -Destination (Join-Path $outDir 'reference_serial.jsonl')
$sourceHash=(Get-FileHash -LiteralPath (Join-Path $outDir 'executed_script.ps1') -Algorithm SHA256).Hash
$logPath=Join-Path $outDir 'serial.jsonl'
$clock=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None;$serial.DtrEnable=$false;$serial.RtsEnable=$false
$serial.ReadTimeout=100;$serial.WriteTimeout=300;$serial.NewLine="`n"
$pending='';$origin=$null;$last=$null;$failure=$null;$targetAttempts=0;$targetsSent=0;$queriesSent=0;$activeStage=$null;$readOnlyStablePassed=$false;$readOnlySteadyMean=$null
$stageResults=[Collections.Generic.List[object]]::new()
function Record([string]$Kind,$Data){[ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;kind=$Kind;data=$Data}|ConvertTo-Json -Depth 10 -Compress|Add-Content -LiteralPath $logPath -Encoding utf8}
function Assert-StopFlag{if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Operator stop flag is present; no further commands'}}
function Check-Unsolicited{
    Assert-StopFlag
    if($serial.BytesToRead -gt 0){$script:pending += $serial.ReadExisting()}
    if($script:pending.Length -eq 0){return}
    Record 'prequery_bytes' $script:pending
    Assert-ControllerText $script:pending
    if(-not $script:pending.EndsWith("`n")){throw 'Incomplete unsolicited frame; refusing to reuse or ignore unknown residual bytes'}
    foreach($line in ($script:pending -split "`n")){
        $obj=Parse-ControllerLine $line
        if($null -ne $obj -and $obj['T'] -eq 1051){throw 'Unsolicited or delayed T1051 before next command; no request correlation available'}
    }
    $script:pending=''
}
function Send-Packet($Packet){
    Assert-StopFlag
    if($Packet['T'] -notin @(105,101)){throw 'Command outside T105/T101 allowlist'}
    if($Packet['T'] -eq 101){
        if($Packet['joint'] -notin @(3,4)){throw 'Only elbow joint 3 and gripper joint 4 may receive targets'}
        if($script:targetAttempts -ge 4){throw 'Maximum four position-target attempts reached'}
        if($Packet['spd'] -ne 100 -or $Packet['acc'] -ne 1){throw 'Unexpected motion speed or acceleration'}
        Assert-Numeric $Packet @('rad')
        $targetField=if($Packet['joint'] -eq 3){'e'}else{'t'}
        if($Packet['rad'] -lt $Limits[$targetField][0] -or $Packet['rad'] -gt $Limits[$targetField][1]){throw 'Single-joint target outside conservative limits'}
        $script:targetAttempts++
    }
    $text=$Packet|ConvertTo-Json -Compress
    Record 'tx_attempt' @{stage=$script:activeStage;packet=$text}
    $serial.WriteLine($text)
    if($Packet['T'] -eq 101){$script:targetsSent++}else{$script:queriesSent++}
}
function Get-Sample{
    Check-Unsolicited
    Send-Packet ([ordered]@{T=105})
    $deadline=$clock.Elapsed.TotalSeconds+.3
    $reply=$null
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        Assert-StopFlag
        if($serial.BytesToRead -gt 0){$script:pending += $serial.ReadExisting()}
        if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
        Assert-ControllerText $script:pending
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n");$line=$script:pending.Substring(0,$idx).TrimEnd("`r");$script:pending=$script:pending.Substring($idx+1)
            Record 'rx' @{stage=$script:activeStage;raw=$line}
            $obj=Parse-ControllerLine $line
            if($null -ne $obj -and $obj['T'] -eq 1051){
                if($null -ne $reply){throw 'Multiple T1051 frames for one query; reply identity is ambiguous'}
                Assert-ModeZero $obj;Assert-Limits $obj
                $reply=$obj
            }
        }
        if($null -ne $reply){
            if($clock.Elapsed.TotalSeconds -gt $deadline){throw 'Feedback arrived beyond 300 ms deadline'}
            if($script:pending.Length -gt 0){throw 'Trailing incomplete frame after feedback; cannot exclude a firmware error'}
            $script:last=$reply
            return $reply
        }
        Start-Sleep -Milliseconds 10
    }
    throw 'Feedback timeout at 300 ms; no blind return or further target'
}
function Target-Packet($Angles,[string]$ActiveField){
    if($ActiveField -notin @('e','t')){throw 'Position target field must be elbow or gripper'}
    $joint=if($ActiveField -eq 'e'){3}else{4}
    return [ordered]@{T=101;joint=$joint;rad=[double]$Angles[$ActiveField];spd=100;acc=1}
}
function Get-StabilityWindow($Frames,[double]$Now){
    $startIndex=-1
    # Include the latest sample at/before Now-1.5, so observed span is at least 1.5 s.
    for($j=$Frames.Count-1;$j -ge 0;$j--){if([double]$Frames[$j]['elapsed_s'] -le $Now-1.5+1e-9){$startIndex=$j;break}}
    $stats=[ordered]@{qualified=$false;span_s=0.0;count=0;peak_to_peak_deg=[ordered]@{};mean_angles_rad=[ordered]@{}}
    if($startIndex -lt 0){return $stats}
    $stats['span_s']=$Now-[double]$Frames[$startIndex]['elapsed_s'];$stats['count']=$Frames.Count-$startIndex
    $stats['qualified']=$stats['span_s'] -ge 1.5-1e-9
    foreach($key in $Fields){
        $values=@(for($j=$startIndex;$j -lt $Frames.Count;$j++){[double]$Frames[$j]['angles_rad'][$key]})
        $m=$values|Measure-Object -Minimum -Maximum -Average
        $stats['peak_to_peak_deg'][$key]=($m.Maximum-$m.Minimum)*180/[math]::PI
        $stats['mean_angles_rad'][$key]=[double]$m.Average
        if($stats['peak_to_peak_deg'][$key] -gt .2+1e-9){$stats['qualified']=$false}
    }
    return $stats
}
function Get-StageAssessment($StartAngles,$Goal,[string]$ActiveField,[bool]$IsReadOnly,[bool]$IsReturn,$ReferenceBaseline,$Frames,[double]$Now,[double]$Begin){
    $sample=$Frames[-1]['angles_rad'];$window=Get-StabilityWindow $Frames $Now
    $assessment=[ordered]@{target_error_deg=[ordered]@{};displacement_from_start_deg=[ordered]@{};return_baseline_error_deg=[ordered]@{};duration_s=$Now-$Begin;stability_window=$window;bounds_violation=$null;target_within_tolerance=$true;movement_verified=$IsReadOnly;commanded_span_deg=$null;signed_active_displacement_deg=$null;return_within_tolerance=(-not $IsReturn);passed=$false}
    foreach($key in $Fields){
        $a=[double]$sample[$key]
        $targetError=($a-[double]$Goal[$key])*180/[math]::PI
        $displacement=($a-[double]$StartAngles[$key])*180/[math]::PI
        $assessment['target_error_deg'][$key]=$targetError
        $assessment['displacement_from_start_deg'][$key]=$displacement
        if($IsReadOnly){
            if([math]::Abs($displacement) -gt 1+1e-9 -and -not $assessment['bounds_violation']){$assessment['bounds_violation']="Read-only $key drift from actual start exceeds 1 degree"}
            if([math]::Abs($targetError) -gt 3+1e-9 -and -not $assessment['bounds_violation']){$assessment['bounds_violation']="Read-only $key deviation from new reference exceeds 3 degrees"}
            if([math]::Abs($targetError) -gt 2+1e-9){$assessment['target_within_tolerance']=$false}
        }elseif($key -ne $ActiveField){
            if([math]::Abs($displacement) -gt 1+1e-9 -and -not $assessment['bounds_violation']){$assessment['bounds_violation']="Inactive $key drift from actual stage start exceeds 1 degree"}
            if([math]::Abs($targetError) -gt 3+1e-9 -and -not $assessment['bounds_violation']){$assessment['bounds_violation']="Inactive $key deviation from new measured reference exceeds 3 degrees"}
        }else{
            $padding=2*[math]::PI/180
            $lo=[math]::Min([double]$StartAngles[$key],[double]$Goal[$key])-$padding
            $hi=[math]::Max([double]$StartAngles[$key],[double]$Goal[$key])+$padding
            if(($a -lt $lo-1e-12 -or $a -gt $hi+1e-12) -and -not $assessment['bounds_violation']){$assessment['bounds_violation']="Active $key angle outside commanded segment plus 2-degree margin"}
            if([math]::Abs($targetError) -gt 2+1e-9){$assessment['target_within_tolerance']=$false}
            $commanded=([double]$Goal[$key]-[double]$StartAngles[$key])*180/[math]::PI
            $signed=[math]::Sign($commanded)*$displacement
            $assessment['commanded_span_deg']=[math]::Abs($commanded)
            $assessment['signed_active_displacement_deg']=$signed
            $assessment['movement_verified']=([math]::Abs($commanded) -gt 1e-9 -and $signed -gt 0 -and $signed+1e-9 -ge .5*[math]::Abs($commanded))
        }
        if($IsReturn){
            if($null -eq $ReferenceBaseline){throw 'Return stage lacks new measured steady baseline'}
            $assessment['return_baseline_error_deg'][$key]=($a-[double]$ReferenceBaseline[$key])*180/[math]::PI
        }
    }
    if($IsReturn){$assessment['return_within_tolerance']=@($Fields|Where-Object{[math]::Abs($assessment['return_baseline_error_deg'][$_]) -gt 1+1e-9}).Count -eq 0}
    $minimumDuration=if($IsReadOnly){2.0}else{4.0}
    # Target and return errors are diagnostics only; user requests functional operation first.
    $assessment['passed']=(-not $assessment['bounds_violation'] -and $assessment['duration_s'] -ge $minimumDuration -and $window['qualified'] -and $assessment['movement_verified'])
    return $assessment
}
function Observe-Stage([string]$Name,$StartAngles,$Goal,[string]$ActiveField,[bool]$IsReadOnly,[bool]$IsReturn=$false){
    $script:activeStage=$Name
    $frames=[Collections.Generic.List[object]]::new()
    $result=[ordered]@{name=$Name;active_field=$ActiveField;read_only=$IsReadOnly;is_return=$IsReturn;start_elapsed_s=$clock.Elapsed.TotalSeconds;start_angles_rad=Copy-Angles $StartAngles;target_angles_rad=Copy-Angles $Goal;observations=$frames;passed=$false;error=$null;end_feedback=$null;target_error_deg=$null;duration_s=0.0;assessment=$null}
    $script:stageResults.Add($result)
    Record 'stage_start' @{name=$Name;read_only=$IsReadOnly;measurement_reference=$Goal;position_command_field=$(if($IsReadOnly){$null}else{$ActiveField});speed_steps_s=$(if($IsReadOnly){$null}else{100});acc_100steps_s2=$(if($IsReadOnly){$null}else{1})}
    try{
        Check-Unsolicited
        if(-not $IsReadOnly){Send-Packet (Target-Packet $Goal $ActiveField)}
        $begin=$clock.Elapsed.TotalSeconds
        $maxSeconds=if($IsReadOnly){2.0}else{8.0}
        do{
            Start-Sleep -Milliseconds 150
            $sample=Get-Sample
            $sampleElapsed=$clock.Elapsed.TotalSeconds
            $frames.Add([ordered]@{elapsed_s=$sampleElapsed;angles_rad=Copy-Angles $sample})
            $result['end_feedback']=$sample
            # Persist this frame's statistics before a bounds exception can exit the stage.
            $assessment=Get-StageAssessment $StartAngles $Goal $ActiveField $IsReadOnly $IsReturn $script:readOnlySteadyMean $frames $sampleElapsed $begin
            $result['assessment']=$assessment;$result['target_error_deg']=$assessment['target_error_deg'];$result['duration_s']=$assessment['duration_s']
            if($assessment['bounds_violation']){throw $assessment['bounds_violation']}
            if($assessment['passed']){$result['passed']=$true;break}
        }while($result['duration_s'] -lt $maxSeconds)
        if(-not $result['passed']){throw 'Stage did not satisfy fixed bounds, actual movement and final 1.5-second stability criteria within its observation limit'}
        Record 'stage_passed' $result
    }catch{
        $result['error']=$_.Exception.Message
        Record 'stage_failed' $result
        throw
    }
}
try{
    $serial.Open();Record 'open' '115200 8N1; DTR/RTS false; no reset requested'
    Start-Sleep -Milliseconds 500
    $activeStage='preflight';$fresh=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 4;$i++){$fresh.Add((Get-Sample));Start-Sleep -Milliseconds 150}
    foreach($key in $Fields){
        $range=$fresh|ForEach-Object{[double]$_[$key]}|Measure-Object -Minimum -Maximum
        if($range.Maximum-$range.Minimum -gt .008){throw 'Current four-frame reference is not stable'}
        foreach($sample in $fresh){if([math]::Abs([double]$sample[$key]-[double]$referenceSamples[-1][$key]) -gt .03){throw "Pose changed since independent reference: $key"}}
    }
    $origin=Copy-Angles $fresh[-1]
    Assert-Limits $origin
    foreach($step in $Steps){$candidate=Copy-Angles $origin;$candidate[$step.field]+=$step.delta_deg*[math]::PI/180;Assert-Limits $candidate}
    Record 'plan' @{origin=$origin;steps=$Steps;read_only_initial_observe_s=2;no_base_or_shoulder_targets=$true;diagnostic_only_target_error_deg=2;leg_min_observe_s=4;leg_max_observe_s=8;stable_window_min_s=1.5;stable_peak_to_peak_max_deg=.2;inactive_max_drift_from_stage_start_deg=1;inactive_max_error_from_new_reference_deg=3;active_min_fraction_of_commanded_span=.5;diagnostic_only_return_to_new_baseline_error_deg=1;precision_thresholds_gate_passing=$false;criteria_predefined=$true;independent_support_asserted=$false;firmware_mode_inferred=0;feedback_freshness_independently_verified=$false;servo13_individually_visible=$false;shoulder_follower_alignment_verified=$false;maximum_target_attempts=4;source_sha256=$sourceHash}
    Observe-Stage 'read_only_current_stability' $origin $origin '' $true
    $readOnlyStablePassed=$true
    $readOnlySteadyMean=Copy-Angles $stageResults[0]['assessment']['stability_window']['mean_angles_rad']
    $origin=Copy-Angles $last
    foreach($step in $Steps){$candidate=Copy-Angles $origin;$candidate[$step.field]+=$step.delta_deg*[math]::PI/180;Assert-Limits $candidate}
    Record 'new_measured_baseline' @{last_angles=$origin;steady_mean=$readOnlySteadyMean;previous_command_targets_imported=$false}
    foreach($step in $Steps){
        $target=Copy-Angles $origin;$target[$step.field]+=$step.delta_deg*[math]::PI/180
        $actualStart=Copy-Angles $last
        Observe-Stage ($step.name+'_outbound') $actualStart $target $step.field $false
        $actualStart=Copy-Angles $last
        Observe-Stage ($step.name+'_return') $actualStart $origin $step.field $false $true
    }
    $activeStage='complete'
}catch{$failure=$_.Exception.Message;try{Record 'failure' $failure}catch{}}
finally{
    # Deliberately zero hardware writes: do not release the arm or send a blind return.
    if($failure){
        Write-Warning 'Test stopped. The last accepted position target may remain active. No automatic torque release, braking, or recovery was sent. Operator takeover is required.' -WarningAction Continue
        try{Record 'operator_takeover_required' 'Stop new targets; previous target may still be active. Host serial close does not disable servo torque or prove holding.'}catch{}
    }
    try{if($serial.IsOpen){$serial.Close()}}catch{if(-not $failure){$failure='Serial close failed: '+$_.Exception.Message}}finally{$serial.Dispose()}
    try{Record 'closed' 'Host serial closed; zero hardware writes in cleanup'}catch{if(-not $failure){$failure='Final log failed: '+$_.Exception.Message}}
}
$result=[ordered]@{port=$Port;device=$ExpectedDevice;output_dir=$outDir;source_sha256=$sourceHash;reference_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_feedback.json') -Algorithm SHA256).Hash;reference_raw_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_serial.jsonl') -Algorithm SHA256).Hash;target_attempts=$targetAttempts;targets_sent=$targetsSent;queries_sent=$queriesSent;read_only_stability_passed=$readOnlyStablePassed;all_five_stages_passed=($stageResults.Count -eq 5 -and @($stageResults|Where-Object{-not $_['passed']}).Count -eq 0 -and -not $failure);origin=$origin;read_only_steady_mean_rad=$readOnlySteadyMean;stages=$stageResults;last_feedback=$last;error=$failure;automatic_torque_release=$false;no_base_or_shoulder_targets=$true;previous_command_targets_imported=$false;independent_support_asserted=$false;stock_feedback_freshness_verified=$false;servo13_individually_visible=$false;shoulder_follower_alignment_verified=$false;precision_thresholds_gate_passing=$false;scope='Elbow and empty-gripper functional diagnostic using new measured reference; no new base or shoulder targets. Absolute target and return errors reported separately, not manufacturer precision, applied holding torque, or shoulder-follower alignment qualification';end_state='Previous device targets may remain active. Closing host serial does not remove servo torque.'}
$result|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result|ConvertTo-Json -Depth 14
if($failure -or -not $result['all_five_stages_passed']){exit 1}

