param([switch]$Execute,[string]$ReferenceFeedbackPath)
$ErrorActionPreference='Stop'
$Port='COM15'
$ExpectedDevice='USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'
$Fields=@('b','s','e','t')
$Limits=@{b=@(-3.0,3.0);s=@(-1.5,1.5);e=@(-.7,3.05);t=@(1.15,5.12)}
$Steps=@(@{name='base';field='b';delta_deg=5.0},@{name='shoulder';field='s';delta_deg=-3.0},@{name='elbow';field='e';delta_deg=-5.0},@{name='empty_gripper';field='t';delta_deg=-15.0})
# Attended empty-arm functional test, not research-control or load qualification.
# User has not supplied an independent support. No support is asserted here.
# No T210, home, mode, PID, calibration or persistent-setting command is allowed.
# Finally performs zero hardware writes. Failure does not automatically release torque.
if(-not $Execute){
    [ordered]@{preview=$true;opens_serial=$false;port=$Port;device=$ExpectedDevice;allowed_commands=@(105,102);maximum_position_target_attempts=9;initial_hold='One measured-current-pose T102, spd 60, acc 1; observe at least 4 seconds';excursions=$Steps;movement='T102, spd 100, acc 1; return after each passed excursion';tolerances='Initial hold <=1 degree, max displacement .02 rad; movement target <=2 degrees, inactive axes <=.02 rad; last five frames stable';requires='Fresh successful raw-error-checked four-frame reference, exact USB identity, new preflight feedback';failure='Stop new writes, close host serial port; previous target may remain active and operator takeover is required';limits_rad=$Limits;scope='Individual servo 13 and physical holding torque cannot be independently verified by stock T1051'}|ConvertTo-Json -Depth 6
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
$outDir=Join-Path 'C:\new\results\hardware_control' ('all_joint_functional_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
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
$pending='';$origin=$null;$last=$null;$failure=$null;$targetAttempts=0;$targetsSent=0;$queriesSent=0;$activeStage=$null;$holdPassed=$false
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
    if($Packet['T'] -notin @(105,102)){throw 'Command outside T105/T102 allowlist'}
    if($Packet['T'] -eq 102){
        if($script:targetAttempts -ge 9){throw 'Maximum nine position-target attempts reached'}
        if($Packet['spd'] -notin @(60,100) -or $Packet['acc'] -ne 1){throw 'Unexpected motion speed or acceleration'}
        Assert-Limits ([ordered]@{b=$Packet['base'];s=$Packet['shoulder'];e=$Packet['elbow'];t=$Packet['hand']})
        $script:targetAttempts++
    }
    $text=$Packet|ConvertTo-Json -Compress
    Record 'tx_attempt' @{stage=$script:activeStage;packet=$text}
    $serial.WriteLine($text)
    if($Packet['T'] -eq 102){$script:targetsSent++}else{$script:queriesSent++}
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
function Target-Packet($Angles,[int]$Speed){return [ordered]@{T=102;base=[double]$Angles['b'];shoulder=[double]$Angles['s'];elbow=[double]$Angles['e'];hand=[double]$Angles['t'];spd=$Speed;acc=1}}
function Observe-Stage([string]$Name,$StartAngles,$Goal,[string]$ActiveField,[bool]$IsHold){
    $script:activeStage=$Name
    $frames=[Collections.Generic.List[object]]::new()
    $result=[ordered]@{name=$Name;active_field=$ActiveField;is_hold=$IsHold;start_elapsed_s=$clock.Elapsed.TotalSeconds;start_angles_rad=Copy-Angles $StartAngles;target_angles_rad=Copy-Angles $Goal;observations=$frames;passed=$false;error=$null;end_feedback=$null;target_error_deg=$null;last_five_stable=$false;duration_s=0.0}
    $script:stageResults.Add($result)
    Record 'stage_start' @{name=$Name;target=$Goal;speed_steps_s=$(if($IsHold){60}else{100});acc_100steps_s2=1}
    try{
        Check-Unsolicited
        Send-Packet (Target-Packet $Goal $(if($IsHold){60}else{100}))
        $begin=$clock.Elapsed.TotalSeconds
        $maxSeconds=if($IsHold){4.0}else{7.0}
        do{
            Start-Sleep -Milliseconds 150
            $sample=Get-Sample
            $sampleElapsed=$clock.Elapsed.TotalSeconds
            $frames.Add([ordered]@{elapsed_s=$sampleElapsed;angles_rad=Copy-Angles $sample})
            $result['end_feedback']=$sample
            $stable=$frames.Count -ge 5
            if($stable){
                for($j=$frames.Count-4;$j -lt $frames.Count;$j++){
                    foreach($key in $Fields){if([math]::Abs([double]$frames[$j]['angles_rad'][$key]-[double]$frames[$j-1]['angles_rad'][$key]) -gt .002){$stable=$false}}
                }
            }
            $errors=[ordered]@{};$within=$true
            foreach($key in $Fields){
                $errors[$key]=([double]$sample[$key]-[double]$Goal[$key])*180/[math]::PI
                if($IsHold -and [math]::Abs($errors[$key]) -gt 1){$within=$false}
                if(-not $IsHold -and $key -eq $ActiveField -and [math]::Abs($errors[$key]) -gt 2){$within=$false}
            }
            # Persist this frame's statistics before a bounds exception can exit the stage.
            $result['target_error_deg']=$errors;$result['last_five_stable']=$stable;$result['duration_s']=$sampleElapsed-$begin
            foreach($key in $Fields){
                $a=[double]$sample[$key]
                if($IsHold -or $key -ne $ActiveField){
                    if([math]::Abs($a-[double]$script:origin[$key]) -gt .02){throw "Uncommanded $key displacement exceeds .02 rad"}
                }else{
                    $padding=2*[math]::PI/180
                    $lo=[math]::Min([double]$StartAngles[$key],[double]$Goal[$key])-$padding
                    $hi=[math]::Max([double]$StartAngles[$key],[double]$Goal[$key])+$padding
                    if($a -lt $lo -or $a -gt $hi){throw "Active $key angle outside commanded segment plus 2-degree margin"}
                }
            }
            if($result['duration_s'] -ge 4 -and $stable -and $within){$result['passed']=$true;break}
        }while($clock.Elapsed.TotalSeconds-$begin -lt $maxSeconds)
        if(-not $result['passed']){throw 'Stage did not reach its angle and last-five-frame stability criteria within observation limit'}
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
    Record 'plan' @{origin=$origin;steps=$Steps;independent_support_asserted=$false;firmware_mode_inferred=0;feedback_freshness_independently_verified=$false;servo13_individually_visible=$false;maximum_target_attempts=9;source_sha256=$sourceHash}
    Observe-Stage 'current_pose_hold' $origin $origin '' $true
    $holdPassed=$true
    foreach($step in $Steps){
        $target=Copy-Angles $origin;$target[$step.field]+=$step.delta_deg*[math]::PI/180
        Observe-Stage ($step.name+'_outbound') $origin $target $step.field $false
        Observe-Stage ($step.name+'_return') $target $origin $step.field $false
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
$result=[ordered]@{port=$Port;device=$ExpectedDevice;output_dir=$outDir;source_sha256=$sourceHash;reference_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_feedback.json') -Algorithm SHA256).Hash;reference_raw_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'reference_serial.jsonl') -Algorithm SHA256).Hash;target_attempts=$targetAttempts;targets_sent=$targetsSent;queries_sent=$queriesSent;hold_gate_passed=$holdPassed;all_nine_stages_passed=($stageResults.Count -eq 9 -and @($stageResults|Where-Object{-not $_['passed']}).Count -eq 0 -and -not $failure);origin=$origin;stages=$stageResults;last_feedback=$last;error=$failure;automatic_torque_release=$false;independent_support_asserted=$false;stock_feedback_freshness_verified=$false;servo13_individually_visible=$false;scope='Attended small-angle functional test; not joint load-capacity, force, precision, timing, or payload-estimation validation';end_state='Last accepted target may remain active. Closing host serial does not remove servo torque.'}
$result|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result|ConvertTo-Json -Depth 14
if($failure -or -not $result['all_nine_stages_passed']){exit 1}
