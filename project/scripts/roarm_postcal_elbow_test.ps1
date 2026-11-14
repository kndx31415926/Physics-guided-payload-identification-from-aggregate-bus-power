param([switch]$Execute,[switch]$IndependentUpperArmSupportConfirmed)
$ErrorActionPreference='Stop'
# Attended post-calibration commissioning only. No serial access in preview.
# The upper arm must be supported independently of the moving forearm.
if(-not $Execute){
    [ordered]@{preview=$true;port='COM15';joint=3;servo_id=14;delta_deg=-5;speed_steps_s=80;acc=1;requires='Independent fixed upper-arm support; forearm can lift without losing support or striking it; no hand support';sequence=@('Four stable T105 samples and mode-0 checks','T101 joint3 at measured current angle; observe 2 seconds','T101 joint3 minus 5 degrees; observe at most 6 seconds','Return only with fresh bounded stable feedback','Success retains the elbow starting-angle target; failure stops new targets without releasing the arm. Neither outcome proves whole-arm holding.');executes_motion=$false} | ConvertTo-Json -Depth 5
    exit 0
}
if(-not $IndependentUpperArmSupportConfirmed){throw 'Independent upper-arm support and clear forearm travel must be confirmed'}
if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Hardware stop flag exists'}
$expectedDevice='USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq 'COM15'
if(-not $device -or $device.PNPDeviceID -ne $expectedDevice){throw 'Expected arm USB identity is absent'}
$expected=@{b=-1.524776903;s=0.016873789;e=([Math]::PI/2);t=3.107845076}
$outDir=Join-Path 'C:\new\results\hardware_control' ('postcal_elbow_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
$sourceHash=(Get-FileHash -LiteralPath (Join-Path $outDir 'executed_script.ps1') -Algorithm SHA256).Hash
$logPath=Join-Path $outDir 'serial.jsonl'
$watch=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new('COM15',115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$serial.ReadTimeout=100
$serial.WriteTimeout=500
$serial.NewLine="`n"
$script:pending=''
$script:last=$null
$script:lastSampleAt=-1.0
$script:origin=$null
$script:motionAttempted=$false
$script:motionCount=0
$script:targetAttempts=[Collections.Generic.List[object]]::new()
$failure=$null
$hold=$null
$outbound=$null
$returned=$null
$success=$false
$releaseAttempted=$false
$releaseHostWritten=$false
$releaseError=$null
$target=$null

function Record([string]$kind,$value){
    [ordered]@{elapsed_s=$watch.Elapsed.TotalSeconds;kind=$kind;value=$value} | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $logPath -Encoding utf8
}
function Check-ControllerText([string]$text){
    if($text -match 'status:\s*failed|Servo ID[^\r\n]*failed|rst:|boot:'){throw 'Servo failure or controller restart text observed'}
}
function Check-Numbers($frame){
    foreach($key in @('T','b','s','e','t','x','y','z')){
        $value=$frame[$key]
        if($null -eq $value -or $value -is [bool] -or $value -is [string] -or $value -isnot [ValueType] -or -not [double]::IsFinite([double]$value)){throw "Invalid numeric feedback: $key"}
    }
}
function Check-ModeZero($frame){
    $b=[double]$frame['b'];$s=[double]$frame['s'];$e=[double]$frame['e']
    $l2=[Math]::Sqrt(236.82*236.82+30*30)
    $l3=[Math]::Sqrt(280.15*280.15+1.73*1.73)
    $t2=[Math]::Atan2(30,236.82)
    $radius=$l2*[Math]::Sin($s+$t2)+$l3*[Math]::Sin($s+$e)
    $z=$l2*[Math]::Cos($s+$t2)+$l3*[Math]::Cos($s+$e)
    if([Math]::Abs($radius*[Math]::Cos($b)-[double]$frame['x']) -gt 0.5 -or [Math]::Abs($radius*[Math]::Sin($b)-[double]$frame['y']) -gt 0.5 -or [Math]::Abs($z-[double]$frame['z']) -gt 0.5){throw 'Feedback does not match audited stock gripper-mode FK'}
}
function Check-Bounds($frame){
    if($null -eq $script:origin){return}
    foreach($key in @('b','s','t')){
        if([Math]::Abs([double]$frame[$key]-[double]$script:origin[$key]) -gt 0.012){throw "Noncommanded joint $key drift exceeded 0.012 rad; no blind return"}
    }
    if([Math]::Abs([double]$frame['e']-[double]$script:origin['e']) -gt 7*[Math]::PI/180){throw 'Elbow excursion exceeded 7 degrees; no blind return'}
}
function Write-Query {
    if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Hardware stop flag exists'}
    Record 'tx_attempt' '{"T":105}'
    $serial.WriteLine('{"T":105}')
}
function Get-Sample([double]$timeoutSeconds=0.8){
    # Retain but discard pre-query host bytes; this is not an MCU acquisition ID.
    if($serial.BytesToRead -gt 0){$script:pending+=$serial.ReadExisting()}
    if($script:pending.Length){
        Record 'prequery_discard' $script:pending
        Check-ControllerText $script:pending
        $script:pending=''
    }
    Write-Query
    $deadline=$watch.Elapsed.TotalSeconds+$timeoutSeconds
    while($watch.Elapsed.TotalSeconds -lt $deadline){
        if($serial.BytesToRead -gt 0){$script:pending+=$serial.ReadExisting()}
        if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
        $latestFrame=$null
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n")
            $line=$script:pending.Substring(0,$idx).TrimEnd("`r")
            $script:pending=$script:pending.Substring($idx+1)
            Record 'rx' $line
            Check-ControllerText $line
            if([string]::IsNullOrWhiteSpace($line)){continue}
            try{$frame=ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop}catch{continue}
            if($null -eq $frame -or $frame -isnot [Collections.IDictionary] -or $frame['T'] -ne 1051){continue}
            Check-Numbers $frame
            Check-ModeZero $frame
            Check-Bounds $frame
            $latestFrame=$frame
        }
        if($null -ne $latestFrame){
            $script:last=$latestFrame
            $script:lastSampleAt=$watch.Elapsed.TotalSeconds
            return $latestFrame
        }
        Start-Sleep -Milliseconds 10
    }
    throw 'No valid post-query feedback before timeout; no blind return'
}
function Is-Stable($frames,[double]$tolerance){
    if($frames.Count -lt 4){return $false}
    foreach($key in @('b','s','e','t')){
        $minimum=[double]::PositiveInfinity
        $maximum=[double]::NegativeInfinity
        foreach($frame in $frames){
            $value=[double]$frame[$key]
            $minimum=[Math]::Min($minimum,$value)
            $maximum=[Math]::Max($maximum,$value)
        }
        if($maximum-$minimum -gt $tolerance){return $false}
    }
    return $true
}
function Write-ElbowTarget([double]$angle,[string]$stage){
    if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Hardware stop flag exists'}
    if($null -eq $script:origin -or $null -eq $script:last){throw 'No validated origin or feedback'}
    if($watch.Elapsed.TotalSeconds-$script:lastSampleAt -gt 0.5){throw 'Last validated feedback is too old for another target'}
    Check-Bounds $script:last
    if(-not [double]::IsFinite($angle) -or $angle -lt 1.35 -or $angle -gt 1.70 -or [Math]::Abs($angle-[double]$script:origin['e']) -gt 5.001*[Math]::PI/180){throw 'Target outside this single-elbow test envelope'}
    if($script:motionCount -ge 3){throw 'Maximum of three elbow targets exceeded'}
    $packet=[ordered]@{T=101;joint=3;rad=$angle;spd=80;acc=1}|ConvertTo-Json -Compress
    Record 'tx_attempt' @{stage=$stage;packet=$packet}
    $script:motionAttempted=$true
    $script:targetAttempts.Add(@{stage=$stage;angle_rad=$angle;elapsed_s=$watch.Elapsed.TotalSeconds})
    $serial.WriteLine($packet)
    $script:motionCount++
}
function Observe-Hold {
    $started=$watch.Elapsed.TotalSeconds
    $recent=[Collections.Generic.List[object]]::new()
    while($watch.Elapsed.TotalSeconds-$started -lt 2.0){
        $sample=Get-Sample
        if([Math]::Abs([double]$sample['e']-[double]$script:origin['e']) -gt 0.012){throw 'Elbow moved unexpectedly while establishing its initial hold'}
        $recent.Add($sample)
        if($recent.Count -gt 4){$recent.RemoveAt(0)}
        Start-Sleep -Milliseconds 100
    }
    if(-not (Is-Stable $recent 0.008)){throw 'Initial elbow hold was not stable for the last four observations'}
    return @{feedback=$script:last;observed_seconds=$watch.Elapsed.TotalSeconds-$started;stable=$true}
}
function Observe-Leg([double]$goal){
    $started=$watch.Elapsed.TotalSeconds
    $recent=[Collections.Generic.List[object]]::new()
    $settled=$false
    while($watch.Elapsed.TotalSeconds-$started -lt 6.0){
        $remaining=6.0-($watch.Elapsed.TotalSeconds-$started)
        if($remaining -lt 0.05){break}
        $sample=Get-Sample ([Math]::Min(0.8,$remaining))
        $recent.Add($sample)
        if($recent.Count -gt 4){$recent.RemoveAt(0)}
        $settled=Is-Stable $recent 0.002
        if($watch.Elapsed.TotalSeconds-$started -ge 2.0 -and $settled){break}
        Start-Sleep -Milliseconds 100
    }
    if($recent.Count -lt 4 -or -not $settled){throw 'Elbow did not settle within six seconds; no blind return'}
    if($watch.Elapsed.TotalSeconds-$script:lastSampleAt -gt 0.5){throw 'Settled feedback is stale; no blind return'}
    $errorDeg=([double]$script:last['e']-$goal)*180/[Math]::PI
    return @{feedback=$script:last;error_deg=$errorDeg;within_1deg=([Math]::Abs($errorDeg) -le 1.0);settled=$settled;observed_seconds=$watch.Elapsed.TotalSeconds-$started;observed_delta_deg=([double]$script:last['e']-[double]$script:origin['e'])*180/[Math]::PI}
}

try{
    Record 'plan' @{expected=$expected;delta_deg=-5;speed_steps_s=80;acc=1;target_tolerance_deg=1;noncommanded_bound_rad=0.012;elbow_excursion_bound_deg=7;external_upper_arm_support_confirmed=$true;physical_end_effector='Gripper; long rod removed';scope='Post-calibration single-elbow commissioning, not payload estimation'}
    $serial.Open()
    Record 'open' 'DTR=false RTS=false; no reset requested'
    Start-Sleep -Milliseconds 300
    $initial=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 4;$i++){
        $sample=Get-Sample
        foreach($key in @('b','s','e','t')){
            if([Math]::Abs([double]$sample[$key]-[double]$expected[$key]) -gt 0.03){throw "Post-calibration preflight pose mismatch: $key"}
        }
        $initial.Add($sample)
        if($i -lt 3){Start-Sleep -Milliseconds 150}
    }
    if(-not (Is-Stable $initial 0.008)){throw 'Initial feedback is not stable'}
    $script:origin=$initial[$initial.Count-1]
    $target=[double]$script:origin['e']-5*[Math]::PI/180
    Record 'origin' $script:origin
    Write-ElbowTarget ([double]$script:origin['e']) 'establish_elbow_hold'
    $hold=Observe-Hold
    Record 'hold' $hold
    Write-ElbowTarget $target 'lift_five_degrees'
    $outbound=Observe-Leg $target
    Record 'outbound' $outbound
    # A bounded, freshly observed stable miss may return; the run still fails.
    Write-ElbowTarget ([double]$script:origin['e']) 'return_to_measured_start'
    $returned=Observe-Leg ([double]$script:origin['e'])
    Record 'returned' $returned
    if(-not $outbound.within_1deg -or -not $returned.within_1deg){throw 'One or both legs missed the predetermined one-degree tolerance'}
    $success=$true
}catch{
    $failure=$_.Exception.Message
    try{Record 'error' $failure}catch{}
}finally{
    try{Record 'closing' @{success=$success;successful_state='Elbow retains its starting-angle target; no other joint was commanded by this script';failure_state='Stop new targets, retain controller state; no automatic release or enable. Actual holding is unverified; fixed support and attended intervention are required.'}}catch{$failure='Final log write failed: '+$_.Exception.Message;$success=$false}
    if(-not $success -and $script:motionAttempted){
        Write-Warning 'Test stopped. Last accepted target may still be powered; holding is unverified. Keep fixed weight-bearing support and take attended control.' -WarningAction Continue
        try{Record 'operator_takeover_required' 'Last accepted target may still be pursued. No blind return, global release, or global enable. This is not an emergency stop.'}catch{}
    }
    if($serial.IsOpen){
        try{$serial.Close()}catch{
            $failure='Serial close failed: '+$_.Exception.Message
            $success=$false
        }
    }
    $serial.Dispose()
}
$result=[ordered]@{
    port='COM15';device=$expectedDevice;joint=3;servo_id=14;success=$success
    position_target_host_writes=$script:motionCount;position_target_attempts=$script:targetAttempts
    origin=$script:origin;target_rad=$target;hold=$hold;outbound=$outbound;returned=$returned
    last_feedback=$script:last;error=$failure;failure_release_attempted=$releaseAttempted
    failure_release_host_write_succeeded=$releaseHostWritten;failure_release_error=$releaseError
    automatic_torque_release=$false;whole_arm_hold_verified=$false
    operator_takeover_required=[bool](-not $success -and $script:motionAttempted)
    output_dir=$outDir;source_sha256=$sourceHash
    limitations=@('Stock feedback has no MCU acquisition timestamp, sequence number or per-sample acquisition-success flag','Post-query host receipt is not proof of an independent newly acquired encoder sample','Shoulder follower ID13 is not independently refreshed by stock T105','No torque-state readback; host write success is not actuation acknowledgement','Mode-0 xyz is computed from encoders, not independent pose metrology','No payload or precision qualification')
    next_step='Keep independent upper-arm support. No home, restart, global torque-on or unsupervised motion.'
}
$result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result|ConvertTo-Json -Depth 12
if(-not $success -or $failure){exit 1}
