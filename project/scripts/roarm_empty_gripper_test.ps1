param([switch]$Execute,[string]$ReferenceFeedbackPath)
$Port='COM15'
$Joint=4
$DeltaDeg=-15.0
$VerifiedGripperStartRad=3.107845076
$ErrorActionPreference='Stop'
# Empty-gripper-only commissioning. Added rod removed; firmware mode 0 verified
# from exact feedback FK and then checked throughout. No mode or explicit torque-switch
# commands. A position-target write can itself enable servo torque.
# Failure stops new targets without releasing other joints. This does not establish arm-body holding.
if(-not $Execute){Write-Output "Dry run: joint $Joint, $DeltaDeg degrees, 100 steps/s, acceleration 1, then return.";exit 0}
if([math]::Abs($DeltaDeg) -lt 5){throw 'This commissioning run requires a visible 5 to 15 degree excursion'}
if([string]::IsNullOrWhiteSpace($ReferenceFeedbackPath)){throw 'Fresh independent all-joint read-only reference required'}
$referenceInfo=Get-Item -LiteralPath $ReferenceFeedbackPath
$referenceAge=((Get-Date)-$referenceInfo.LastWriteTime).TotalSeconds
if($referenceAge -lt -5 -or $referenceAge -gt 600){throw 'Reference snapshot is not recent'}
$reference=Get-Content -Raw -LiteralPath $ReferenceFeedbackPath|ConvertFrom-Json -AsHashtable
if($reference['port'] -ne $Port -or $reference['device'] -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4' -or $reference['motion_commands_sent'] -ne 0 -or $null -ne $reference['error'] -or $reference['feedback'].Count -lt 4){throw 'Invalid reference identity or acquisition'}
$expectedBody=$reference['feedback'][-1]
foreach($k in @('b','s','e','t')){
    $values=@()
    foreach($sample in $reference['feedback']){
        $v=$sample[$k]
        if($null -eq $v -or $v -is [string] -or $v -is [bool] -or $v -isnot [ValueType] -or -not [double]::IsFinite([double]$v)){throw 'Invalid numeric reference'}
        $values+=,[double]$v
    }
    $range=$values|Measure-Object -Minimum -Maximum
    if($range.Maximum-$range.Minimum -gt .008){throw 'Reference is not stable'}
}
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq $Port
if(-not $device -or $device.PNPDeviceID -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'){throw 'Commissioned USB controller not found'}
$field=@{2='s';3='e';4='t'}[$Joint]
$outDir=Join-Path 'C:\new\results\hardware_control' ('empty_gripper_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
Copy-Item -LiteralPath $ReferenceFeedbackPath -Destination (Join-Path $outDir 'reference_feedback.json')
$logPath=Join-Path $outDir 'serial.jsonl'
$clock=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None;$serial.DtrEnable=$false;$serial.RtsEnable=$false
$serial.ReadTimeout=100;$serial.WriteTimeout=500;$serial.NewLine="`n"
$pending='';$origin=$null;$last=$null;$target=$null;$failure=$null;$motionCount=0;$motionAttempted=$false;$outbound=$null;$returned=$null
function Record([string]$Kind,$Data){
    [ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;kind=$Kind;data=$Data} | ConvertTo-Json -Depth 7 -Compress | Add-Content -LiteralPath $logPath -Encoding utf8
}
function Send-Packet($Packet){
    if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Stop flag present; no further commands'}
    if($Packet.T -notin @(105,101) -or ($Packet.T -eq 101 -and $Packet.joint -ne 4)){throw 'Wrong joint'}
    if($Packet.T -eq 101 -and $motionCount -ge 2){throw 'Maximum two gripper targets exceeded'}
    $text=$Packet|ConvertTo-Json -Compress;Record 'tx_attempt' $text
    if($Packet.T -eq 101){$script:motionAttempted=$true}
    $serial.WriteLine($text)
    if($Packet.T -eq 101){$script:motionCount++}
}
function Check-ModeZero($obj){
    $s=[double]$obj['s'];$e=[double]$obj['e'];$b=[double]$obj['b']
    $l2=[math]::Sqrt(236.82*236.82+30*30);$l3=[math]::Sqrt(280.15*280.15+1.73*1.73);$t2=[math]::Atan2(30,236.82)
    $r=$l2*[math]::Sin($s+$t2)+$l3*[math]::Sin($s+$e)
    $z=$l2*[math]::Cos($s+$t2)+$l3*[math]::Cos($s+$e)
    if([math]::Abs($r*[math]::Cos($b)-[double]$obj['x']) -gt .5 -or [math]::Abs($r*[math]::Sin($b)-[double]$obj['y']) -gt .5 -or [math]::Abs($z-[double]$obj['z']) -gt .5){throw 'Feedback no longer matches audited mode-0 mapping; no further motion'}
}
function Check-ControllerText([string]$text){if($text -match 'status:\s*failed|Servo ID[^\r\n]*failed|rst:|boot:'){throw 'Servo failure or controller restart reported'}}
function Get-Sample {
    # Drop and retain pre-query bytes so previous replies cannot be reused.
    if($serial.BytesToRead -gt 0){$script:pending += $serial.ReadExisting()}
    if($script:pending.Length){Record 'prequery_discard' $script:pending;Check-ControllerText $script:pending;$script:pending=''}
    Send-Packet @{T=105}
    $deadline=$clock.Elapsed.TotalSeconds+1
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        if($serial.BytesToRead -gt 0){$script:pending += $serial.ReadExisting()}
        if($script:pending.Length -gt 32768){throw 'Receive overflow'}
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n");$line=$script:pending.Substring(0,$idx).TrimEnd("`r");$script:pending=$script:pending.Substring($idx+1)
            Record 'rx' $line
            Check-ControllerText $line
            try{$obj=$line|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{continue}
            if($null -eq $obj -or $obj -isnot [System.Collections.IDictionary] -or $obj['T'] -ne 1051){continue}
            foreach($k in @('b','s','e','t','x','y','z')){
                if(-not $obj.Contains($k) -or $null -eq $obj[$k] -or $obj[$k] -is [string] -or $obj[$k] -is [bool] -or -not [double]::IsFinite([double]$obj[$k])){throw 'Invalid numeric feedback'}
            }
            Check-ModeZero $obj
            $script:last=$obj;return $obj
        }
        Start-Sleep -Milliseconds 10
    }
    throw 'Feedback timeout; no blind return'
}
function Check-Excursion($obj){
    foreach($k in @('b','s','e','t')){
        $bound=if($k -eq $field){([math]::Abs($DeltaDeg)+3)*[math]::PI/180}else{.012}
        if([math]::Abs([double]$obj[$k]-[double]$script:origin[$k]) -gt $bound){throw "Unexpected $k excursion; no further commands"}
    }
}
function Observe([double]$Goal){
    $start=$clock.Elapsed.TotalSeconds;$lastAngle=$null;$stable=0;$latest=$null
    while($clock.Elapsed.TotalSeconds-$start -lt 5){
        Start-Sleep -Milliseconds 150;$latest=Get-Sample;Check-Excursion $latest
        $angle=[double]$latest[$field]
        if($null -ne $lastAngle -and [math]::Abs($angle-$lastAngle) -le .002){$stable++}else{$stable=0}
        $lastAngle=$angle
        if($clock.Elapsed.TotalSeconds-$start -ge 2 -and $stable -ge 4){break}
    }
    $err=([double]$latest[$field]-$Goal)*180/[math]::PI
    return [ordered]@{feedback=$latest;error_deg=$err;settled=($stable -ge 4);within_2deg=([math]::Abs($err) -le 2);observed_delta_deg=([double]$latest[$field]-[double]$script:origin[$field])*180/[math]::PI}
}
try{
    $serial.Open();Record 'open' 'DTR/RTS false; no intentional reset';Start-Sleep -Milliseconds 500
    $samples=@();for($i=0;$i -lt 4;$i++){$samples+=,(Get-Sample);Start-Sleep -Milliseconds 200}
    $origin=$samples[-1]
    foreach($k in @('b','s','e','t')){$range=$samples|ForEach-Object{[double]$_[$k]}|Measure-Object -Minimum -Maximum;if($range.Maximum-$range.Minimum -gt .008){throw 'Arm not stable before motion'}}
    foreach($sample in $samples){foreach($k in @('b','s','e','t')){if([math]::Abs([double]$sample[$k]-[double]$expectedBody[$k]) -gt .03){throw "Initial pose changed since independent reference: $k"}}}
    if([math]::Abs([double]$origin['t']-$VerifiedGripperStartRad) -gt .03){throw 'Gripper is outside the previously exercised start-angle interval'}
    $target=[double]$origin[$field]+$DeltaDeg*[math]::PI/180
    $limits=switch($Joint){2{@(-1.50,1.50)}3{@(-.70,3.05)}4{@(1.15,5.12)}}
    foreach($angle in @([double]$origin[$field],$target)){if($angle -lt $limits[0] -or $angle -gt $limits[1]){throw 'Command outside conservative wire limits'}}
    Record 'plan' @{joint=$Joint;origin=$origin;target_rad=$target;delta_deg=$DeltaDeg;speed_steps_s=100;acc_100steps_s2=1;firmware_mode=0;physical_end_effector='Empty gripper; added long rod removed';scope='Visible movement and approximate return, 2-degree commissioning tolerance; not precision qualification'}
    Send-Packet @{T=101;joint=$Joint;rad=$target;spd=100;acc=1};$outbound=Observe $target
    if(-not $outbound.within_2deg -or -not $outbound.settled){throw 'Gripper opening did not reach and settle; stop new targets without a blind return'}
    for($i=0;$i -lt 4;$i++){Start-Sleep -Milliseconds 150;$sample=Get-Sample;Check-Excursion $sample}
    Send-Packet @{T=101;joint=$Joint;rad=[double]$origin[$field];spd=100;acc=1};$returned=Observe ([double]$origin[$field])
    if(-not $returned.within_2deg -or -not $returned.settled){throw 'Gripper return did not reach and settle; stop new targets without extra attempts'}
}catch{$failure=$_.Exception.Message;Record 'error' $failure}
finally{
    if($failure){
        Write-Warning 'Gripper test stopped. Last accepted gripper target may still be active. The script sent no arm-body targets or explicit torque-switch commands; attended intervention is required.' -WarningAction Continue
        try{Record 'operator_takeover_required' 'No further targets or torque commands. Last accepted target may remain active; holding is NOT verified. A gripper error must not release the arm body.'}catch{}
    }
    try{if($serial.IsOpen){$serial.Close()}}finally{$serial.Dispose()}
    try{Record 'closed' 'No automatic torque release/enable, home or mode command. Only gripper targets were sent; arm-body holding was not established.'}catch{if(-not $failure){$failure='Final log write failed: '+$_.Exception.Message}}
}
$result=[ordered]@{joint=$Joint;field=$field;port=$Port;device=$device.PNPDeviceID;motion_commands_sent=$motionCount;motion_attempted=$motionAttempted;automatic_torque_release=$false;whole_arm_hold_verified=$false;origin=$origin;target_rad=$target;outbound=$outbound;returned=$returned;last_feedback=$last;error=$failure;output_dir=$outDir;scope='Stock single-joint commissioning, not payload or research-interface validation';source_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'executed_script.ps1') -Algorithm SHA256).Hash}
$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result|ConvertTo-Json -Depth 10
if($failure -or -not $outbound.within_2deg -or -not $returned.within_2deg -or -not $returned.settled){exit 1}

