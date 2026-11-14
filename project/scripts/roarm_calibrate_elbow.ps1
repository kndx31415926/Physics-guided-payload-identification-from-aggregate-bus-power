param([switch]$Execute,[switch]$Supported,[switch]$ReferencePoseConfirmed,[string]$ReferenceFeedbackPath)
$ErrorActionPreference='Stop'
# Single-use, attended service operation. No position targets, restart, homing,
# torque-on or calibration of the other four servos. Default is an offline preview.
$expected=@{}
if(-not $Execute){
    [ordered]@{preview=$true;servo=14;requires='Live user confirmation of external support, 12 V on, and shown L pose';sequence=@('T105 preflight','T210 cmd0 release','T105 stability check','T502 id14 calibrate once','T210 cmd0 release again','T105 verify');position_targets_sent=0} | ConvertTo-Json -Depth 5
    exit 0
}
if(-not $Supported -or -not $ReferencePoseConfirmed){throw 'External support and physical reference pose must be confirmed before execute'}
if([string]::IsNullOrWhiteSpace($ReferenceFeedbackPath)){throw 'An explicit fresh read-only reference snapshot is required'}
$referenceFile=Get-Item -LiteralPath $ReferenceFeedbackPath
$referenceAge=((Get-Date)-$referenceFile.LastWriteTime).TotalSeconds
if($referenceAge -lt -5 -or $referenceAge -gt 600){throw 'Reference snapshot must be from the past 10 minutes'}
$reference=Get-Content -Raw -LiteralPath $ReferenceFeedbackPath | ConvertFrom-Json -AsHashtable
if($reference['port'] -ne 'COM15' -or $reference['device'] -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4' -or $reference['motion_commands_sent'] -ne 0 -or $null -ne $reference['error'] -or $reference['feedback'].Count -lt 4){throw 'Invalid read-only reference identity or acquisition'}
$referenceLast=$reference['feedback'][-1]
foreach($key in @('b','s','e','t')){
    foreach($sample in $reference['feedback']){
        $v=$sample[$key]
        $last=$referenceLast[$key]
        if($null -eq $v -or $v -is [bool] -or $v -is [string] -or $v -isnot [ValueType] -or -not [double]::IsFinite([double]$v)){throw 'Invalid reference number'}
        if($null -eq $last -or $last -is [bool] -or $last -is [string] -or $last -isnot [ValueType] -or -not [double]::IsFinite([double]$last)){throw 'Invalid final reference number'}
        if([Math]::Abs([double]$v-[double]$last) -gt 0.008){throw 'Reference feedback was not stable'}
    }
    $expected[$key]=[double]$referenceLast[$key]
}
$referenceHash=(Get-FileHash -LiteralPath $ReferenceFeedbackPath -Algorithm SHA256).Hash
if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Hardware stop flag exists'}
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq 'COM15'
if(-not $device -or $device.PNPDeviceID -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'){throw 'Expected arm USB identity is absent'}
$outDir=Join-Path 'C:\new\results\hardware_control' ('elbow_midpoint_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
Copy-Item -LiteralPath $ReferenceFeedbackPath -Destination (Join-Path $outDir 'reference_feedback.json')
$log=Join-Path $outDir 'serial.jsonl'
$watch=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new('COM15',115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$serial.ReadTimeout=200
$serial.WriteTimeout=1000
$serial.NewLine="`n"
$script:pending=''
$script:frames=[Collections.Generic.List[object]]::new()
$script:rxFailure=$false
$releaseSent=$false
$finalReleaseWritten=$false
$calibrationAttempted=$false
$verified=$false
$failure=$null
$before=$null
$released=$null
$after=$null
function Record([string]$kind,$value){
    [ordered]@{elapsed_s=$watch.Elapsed.TotalSeconds;kind=$kind;value=$value} | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $log -Encoding utf8
}
function Receive([double]$seconds){
    $deadline=$watch.Elapsed.TotalSeconds+$seconds
    while($watch.Elapsed.TotalSeconds -lt $deadline){
        if($serial.BytesToRead -gt 0){
            $script:pending+=$serial.ReadExisting()
            if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
            while($script:pending.Contains("`n")){
                $idx=$script:pending.IndexOf("`n")
                $line=$script:pending.Substring(0,$idx).TrimEnd("`r")
                $script:pending=$script:pending.Substring($idx+1)
                Record 'rx' $line
                if($line -match 'status:\s*failed|rst:|boot:'){ $script:rxFailure=$true }
                if([string]::IsNullOrWhiteSpace($line)){continue}
                try{$obj=ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop}catch{continue}
                if($null -ne $obj -and $obj['T'] -eq 1051){$script:frames.Add($obj)}
            }
        }
        Start-Sleep -Milliseconds 10
    }
}
function Send([string]$packet){
    if($packet -notin @('{"T":105}','{"T":210,"cmd":0}','{"T":502,"id":14}')){throw 'Packet is not whitelisted'}
    if($packet -ne '{"T":210,"cmd":0}' -and (Test-Path -LiteralPath 'C:\new\hardware_stop.flag')){throw 'Hardware stop flag exists'}
    Record 'tx_attempt' $packet
    $serial.WriteLine($packet)
}
function Sample {
    Receive 0.05
    $count=$script:frames.Count
    Send '{"T":105}'
    Receive 0.45
    if($script:rxFailure){throw 'Servo failure or controller restart text observed'}
    if($script:frames.Count -le $count){throw 'No feedback after query; no calibration retry'}
    $f=$script:frames[$script:frames.Count-1]
    foreach($key in @('b','s','e','t')){
        $v=$f[$key]
        if($null -eq $v -or $v -is [bool] -or $v -is [string] -or $v -isnot [ValueType] -or -not [double]::IsFinite([double]$v)){throw "Invalid numeric feedback $key"}
    }
    return $f
}
function CheckPose($f,$ref,[double]$tol){
    foreach($key in @('b','s','e','t')){
        if([Math]::Abs([double]$f[$key]-[double]$ref[$key]) -gt $tol){throw "Unexpected pose or drift in $key"}
    }
}
try{
    Record 'reference' @{path=$ReferenceFeedbackPath;sha256=$referenceHash;expected=$expected;physical_pose_confirmed_by_user=$true}
    $serial.Open()
    Record 'open' 'DTR=false RTS=false; no reset requested'
    Receive 1
    for($i=0;$i -lt 4;$i++){
        $f=Sample
        CheckPose $f $expected 0.035
        if($null -ne $before){CheckPose $f $before 0.008}
        $before=$f
    }
    Record 'before' $before
    # The user must have supported both arm links before this broadcast release.
    $releaseSent=$true
    Send '{"T":210,"cmd":0}'
    Receive 0.15
    for($i=0;$i -lt 4;$i++){
        $released=Sample
        CheckPose $released $before 0.012
    }
    Record 'after_release' $released
    # Persistent write, performed exactly once. No automatic retry on uncertainty.
    $calibrationAttempted=$true
    Send '{"T":502,"id":14}'
    Receive 0.15
    Send '{"T":210,"cmd":0}'
    Receive 0.15
    $calibratedReference=@{b=$released['b'];s=$released['s'];e=([Math]::PI/2);t=$released['t']}
    for($i=0;$i -lt 4;$i++){
        $after=Sample
        CheckPose $after $calibratedReference 0.012
    }
    $verified=$true
    Record 'verified_reported_angles' $after
}catch{
    $failure=$_.Exception.Message
    Record 'error' $failure
}finally{
    if($releaseSent -and $serial.IsOpen){
        try{
            # A logging fault must not prevent this final best-effort release.
            $serial.WriteLine('{"T":210,"cmd":0}')
            $finalReleaseWritten=$true
            Record 'final_release_host_write_succeeded' '{"T":210,"cmd":0}'
            Receive 0.1
        }catch{
            $failure='Final release or its recording failed: '+$_.Exception.Message
            try{Record 'final_release_error' $failure}catch{}
        }
    }
    if($releaseSent -and -not $finalReleaseWritten){
        $failure='Final release host write was not confirmed; maintain external support'
    }
    if($serial.IsOpen){$serial.Close()}
    $serial.Dispose()
    Record 'closed' 'No position targets or torque-on commands; external support must remain'
    [ordered]@{port='COM15';servo_id=14;position_targets_sent=0;release_requested=$releaseSent;final_release_host_write_succeeded=$finalReleaseWritten;calibration_attempted=$calibrationAttempted;reported_angle_verification_passed=$verified;before=$before;after=$after;error=$failure;output_dir=$outDir;limitations=@('Stock firmware lacks torque-state and individual calibration acknowledgement','No original EEPROM offset readback available','No independent pose metrology or servo acquisition-success bits','No restart or power-cycle persistence test','Shoulder follower not independently verified');next_step='Keep external support. Do not restart, home or globally enable torque. Recovery of holding is a separate attended step.'} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
}
Get-Content -LiteralPath (Join-Path $outDir 'summary.json')
if($failure -or -not $verified){exit 1}
