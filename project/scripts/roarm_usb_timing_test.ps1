param([switch]$Execute,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$stages=@(
    @{name='warmup_10hz';hz=10.0;count=20},
    @{name='baseline_10hz';hz=10.0;count=100},
    @{name='main_20hz_r1';hz=20.0;count=1200},
    @{name='main_20hz_r2';hz=20.0;count=1200},
    @{name='main_20hz_r3';hz=20.0;count=1200},
    @{name='stress_30hz';hz=30.0;count=300},
    @{name='stress_40hz';hz=40.0;count=400}
)
if(-not $Execute){[ordered]@{preview=$true;port='COM15';only_packet='{"T":105}\n';motion_commands=0;stages=$stages;nominal_duration_s=212;timeout_s=.1;single_outstanding_request=$true}|ConvertTo-Json -Depth 5;exit 0}
$identity='USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq 'COM15'
if(-not $device -or $device.PNPDeviceID -ne $identity){throw 'Expected USB identity is absent'}
if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Stop flag is present'}
if([string]::IsNullOrEmpty($OutputDirectory)){$OutputDirectory=Join-Path 'C:\new\results\hardware_control' ('usb_timing_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Output already exists; refusing overwrite'}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $OutputDirectory 'executed_script.ps1')
$hash=(Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'executed_script.ps1') -Algorithm SHA256).Hash
$clock=[Diagnostics.Stopwatch]::StartNew()
$rows=[Collections.Generic.List[object]]::new()
$raw=[Collections.Generic.List[object]]::new()
$serial=[IO.Ports.SerialPort]::new('COM15',115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None;$serial.DtrEnable=$false;$serial.RtsEnable=$false
$serial.ReadTimeout=10;$serial.WriteTimeout=100;$serial.NewLine="`n"
$script:pending='';$script:active=$null;$script:currentStage='startup';$script:lastTx=-1000.0
$script:rawCursor=0;$script:csvCursor=0;$script:lastCheckpointMs=0.0
$failure=$null;$completedStages=[Collections.Generic.List[string]]::new()
$metadata=[ordered]@{
    schema='roarm_readonly_usb_timing_v1';utc_started=[DateTime]::UtcNow.ToString('o')
    port='COM15';device=$identity;baud=115200;format='8N1 LF JSON'
    script_sha256=$hash;stopwatch_frequency_hz=[Diagnostics.Stopwatch]::Frequency
    stopwatch_high_resolution=[Diagnostics.Stopwatch]::IsHighResolution
    powershell_version=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString
    stages=$stages;packet_utf8_bytes=10;request_timeout_s=.100;feedback_age_contract_s=.080
    scheduling='next start >= previous actual start + period; one outstanding request, no catch-up bursts'
    poll_sleep_ms=1;source_acquisition_verified=$false;motion_commands_sent=0
    timing_scope='Host write start to host-observed complete reply; not one-way delay, device sample time, command execution or internal servo period.'
    host_stack='PowerShell and .NET SerialPort, not the full MATLAB trajectory controller'
}
$metadata|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputDirectory 'metadata.json') -Encoding utf8
function Save-Checkpoint([string]$state){
    $before=$clock.Elapsed.TotalSeconds
    if($rows.Count -gt $script:csvCursor){
        $batch=$rows.GetRange($script:csvCursor,$rows.Count-$script:csvCursor)
        $path=Join-Path $OutputDirectory 'samples.csv'
        if($script:csvCursor -eq 0){$batch|Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8}
        else{$batch|Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8 -Append}
        $script:csvCursor=$rows.Count
    }
    if($raw.Count -gt $script:rawCursor){
        $batch=$raw.GetRange($script:rawCursor,$raw.Count-$script:rawCursor)
        $batch|ForEach-Object{$_|ConvertTo-Json -Depth 4 -Compress}|Add-Content -LiteralPath (Join-Path $OutputDirectory 'serial.jsonl') -Encoding utf8
        $script:rawCursor=$raw.Count
    }
    $script:lastCheckpointMs=1000*($clock.Elapsed.TotalSeconds-$before)
    [ordered]@{state=$state;stage=$script:currentStage;samples=$rows.Count;elapsed_s=$clock.Elapsed.TotalSeconds;completed_stages=@($completedStages.ToArray());error=$failure;last_checkpoint_ms=$script:lastCheckpointMs;motion_commands_sent=0;output_dir=$OutputDirectory}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutputDirectory 'status.json') -Encoding utf8
}
function Check-Stop {
    if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Stop flag present; read-only measurement stopped'}
}
function Poll-Lines([bool]$Startup=$false){
    if($serial.BytesToRead -gt 0){
        $chunk=$serial.ReadExisting();$noticed=$clock.Elapsed.TotalSeconds
        if($null -ne $script:active -and $null -eq $script:active.first_byte_s){$script:active.first_byte_s=$noticed}
        $script:pending+=$chunk
        if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n");$lineWithTerminator=$script:pending.Substring(0,$idx+1);$line=$script:pending.Substring(0,$idx).TrimEnd("`r");$script:pending=$script:pending.Substring($idx+1)
            $receipt=$noticed
            $requestIndex=if($null -eq $script:active){$null}else{$script:active.request_index}
            $raw.Add([ordered]@{elapsed_s=$receipt;stage=$script:currentStage;request_index=$requestIndex;kind='rx';raw=$line})
            if($line -match 'status:\s*failed|Servo ID[^\r\n]*failed|rst:|boot:'){throw 'Device read failure or restart text observed'}
            try{$obj=$line|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{continue}
            if($null -eq $obj -or $obj -isnot [Collections.IDictionary]){continue}
            if($obj['T'] -eq 1005 -and $obj['status'] -eq 0){throw "Device reports servo read failure: $($obj['id'])"}
            if($obj['T'] -ne 1051){continue}
            if($Startup){throw 'Unsolicited angle streaming found; cannot correlate stock responses'}
            if($null -eq $script:active -or $null -ne $script:active.rx_frame_s){throw 'Extra angle frame; stock request association is ambiguous'}
            foreach($key in @('b','s','e','t','x','y','z')){
                $v=$obj[$key]
                if($null -eq $v -or $v -is [string] -or $v -is [bool] -or $v -isnot [ValueType] -or -not [double]::IsFinite([double]$v)){throw "Invalid angle/position field $key"}
            }
            $script:active.rx_frame_s=$receipt
            $script:active.response_bytes=[Text.Encoding]::UTF8.GetByteCount($lineWithTerminator)
            foreach($key in @('b','s','e','t')){$script:active[$key]=[double]$obj[$key]}
            $script:active.parse_end_s=$clock.Elapsed.TotalSeconds
            $script:active.status='ok'
        }
    }
}
try{
    $serial.Open()
    $raw.Add([ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;stage='startup';kind='open';raw='DTR=false RTS=false; no reset requested'})
    $drainUntil=$clock.Elapsed.TotalSeconds+1
    while($clock.Elapsed.TotalSeconds -lt $drainUntil){Poll-Lines $true;Start-Sleep -Milliseconds 1}
    if($script:pending.Length){throw 'Incomplete startup line; clean stock-response association not established'}
    foreach($stage in $stages){
        $script:currentStage=$stage.name;$period=1.0/[double]$stage.hz
        Save-Checkpoint 'running'
        for($i=1;$i -le $stage.count;$i++){
            Check-Stop
            $due=if($script:lastTx -lt 0){$clock.Elapsed.TotalSeconds}else{$script:lastTx+$period}
            while($clock.Elapsed.TotalSeconds -lt $due){Poll-Lines;Start-Sleep -Milliseconds 1}
            Poll-Lines
            if($script:pending.Length){throw 'Unmatched partial response before next query'}
            $script:active=[ordered]@{stage=$stage.name;request_index=$i;target_hz=$stage.hz;period_s=$period;due_s=$due;tx_start_s=$null;write_end_s=$null;first_byte_s=$null;rx_frame_s=$null;parse_end_s=$null;response_bytes=$null;status='write_attempted';b=$null;s=$null;e=$null;t=$null}
            # The literal below is the ONLY outbound serial packet in this script.
            $script:active.tx_start_s=$clock.Elapsed.TotalSeconds;$script:lastTx=$script:active.tx_start_s
            $serial.WriteLine('{"T":105}')
            $script:active.write_end_s=$clock.Elapsed.TotalSeconds
            $deadline=$script:active.tx_start_s+.100
            while($null -eq $script:active.rx_frame_s){
                Poll-Lines
                if($null -ne $script:active.rx_frame_s){break}
                if($clock.Elapsed.TotalSeconds -ge $deadline){$script:active.status='timeout';throw 'No complete response within 100 ms; stop rather than reuse a late reply'}
                Start-Sleep -Milliseconds 1
            }
            if($script:active.rx_frame_s -gt $deadline){$script:active.status='late_over_timeout';throw 'Reply observed after the 100-ms limit'}
            $rows.Add([pscustomobject]$script:active);$script:active=$null
            if(($i % 100) -eq 0){Save-Checkpoint 'running'}
        }
        $completedStages.Add($stage.name);Save-Checkpoint 'running'
    }
}catch{
    $failure=$_.Exception.Message
    if($null -ne $script:active){
        if($script:active.status -eq 'write_attempted' -or $script:active.status -eq 'ok'){$script:active.status='error'}
        $rows.Add([pscustomobject]$script:active);$script:active=$null
    }
    $raw.Add([ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;stage=$script:currentStage;kind='error';raw=$failure})
}finally{
    try{if($serial.IsOpen){$serial.Close()}}catch{$failure='Port close error: '+$_.Exception.Message}finally{$serial.Dispose()}
    $raw.Add([ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;stage=$script:currentStage;kind='closed';raw='No motion, mode, reset, calibration or torque packet sent'})
    Save-Checkpoint $(if($failure){'failed'}else{'complete'})
}
[ordered]@{error=$failure;completed_stages=@($completedStages.ToArray());observations=$rows.Count;motion_commands_sent=0;output_dir=$OutputDirectory}|ConvertTo-Json -Depth 5
if($failure){exit 1}
