param([Parameter(Mandatory=$true)][string]$Port,[switch]$Execute)
$ErrorActionPreference='Stop'
if(-not $Execute){Write-Output 'Dry run: read stock feedback; base-only +10 degrees at 100 steps/s, acceleration 1; return to measured start. Requires operator-cleared workspace.';exit 0}
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq $Port
if(-not $device -or $device.PNPDeviceID -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'){throw 'Expected commissioned USB controller identity not present'}
$outDir=Join-Path 'C:\new\results\hardware_control' ('usb_micro_move_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir | Out-Null
$logPath=Join-Path $outDir 'serial.jsonl'
$clock=[Diagnostics.Stopwatch]::StartNew()
$serial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None;$serial.DtrEnable=$false;$serial.RtsEnable=$false
$serial.ReadTimeout=100;$serial.WriteTimeout=500;$serial.NewLine="`n"
$pending='';$motionCount=0;$origin=$null;$target=$null;$last=$null;$failure=$null;$outboundConfirmed=$false;$returnConfirmed=$false
function Record([string]$Kind,$Data){
    [ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;kind=$Kind;data=$Data} | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $logPath -Encoding utf8
}
function Send-Packet($Packet){
    if(Test-Path -LiteralPath 'C:\new\hardware_stop.flag'){throw 'Operator stop flag present; no further command'}
    $text=$Packet | ConvertTo-Json -Compress
    Record 'tx_attempt' $text
    $serial.WriteLine($text)
    if($Packet.T -eq 101){$script:motionCount++}
}
function Get-Sample {
    Send-Packet @{T=105}
    $deadline=$clock.Elapsed.TotalSeconds+1
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        if($serial.BytesToRead -gt 0){$script:pending += $serial.ReadExisting()}
        if($script:pending.Length -gt 32768){throw 'Receive overflow'}
        while($script:pending.Contains("`n")){
            $idx=$script:pending.IndexOf("`n");$line=$script:pending.Substring(0,$idx).TrimEnd("`r");$script:pending=$script:pending.Substring($idx+1)
            Record 'rx' $line
            if($line -match 'Servo ID.*failed'){throw 'Controller reported a servo read failure'}
            try{$obj=$line | ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{continue}
            if($null -eq $obj -or $obj -isnot [System.Collections.IDictionary]){continue}
            if($obj['T'] -eq 1051){
                foreach($key in @('b','s','e','t')){
                    if(-not $obj.Contains($key) -or $null -eq $obj[$key] -or $obj[$key] -is [string] -or $obj[$key] -is [bool] -or -not [double]::IsFinite([double]$obj[$key])){throw 'Missing, nonnumeric or nonfinite joint feedback'}
                }
                $script:last=$obj
                return $obj
            }
        }
        Start-Sleep -Milliseconds 10
    }
    throw 'No stock feedback within one second; no further motion command'
}
function Observe-Target([double]$BaseTarget){
    $deadline=$clock.Elapsed.TotalSeconds+6
    $matches=0
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        Start-Sleep -Milliseconds 150
        $sample=Get-Sample
        if([math]::Abs([double]$sample['b']-[double]$script:origin['b']) -gt .21){throw 'Base exceeded commissioning excursion bound'}
        foreach($key in @('s','e','t')){if([math]::Abs([double]$sample[$key]-[double]$script:origin[$key]) -gt .04){throw 'Uncommanded joint change detected; no further commands'}}
        if([math]::Abs([double]$sample['b']-$BaseTarget) -le .005){$matches++}else{$matches=0}
        if($matches -ge 3){return $true}
    }
    return $false
}
try{
    $serial.Open();Record 'open' 'DTR/RTS false; no intentional reset; stock commissioning only'
    Start-Sleep -Milliseconds 500
    $samples=@()
    for($i=0;$i -lt 4;$i++){$samples+=,(Get-Sample);Start-Sleep -Milliseconds 200}
    $origin=$samples[-1]
    foreach($key in @('b','s','e','t')){
        $range=$samples | ForEach-Object {[double]$_[''+$key]} | Measure-Object -Minimum -Maximum
        if(($range.Maximum-$range.Minimum) -gt .008){throw 'Arm is not stable; no motion sent'}
    }
    if([math]::Abs([double]$origin['b']) -gt 2.9){throw 'Base too close to travel boundary'}
    if([math]::Abs([double]$origin['b']-(-1.53858273)) -gt .02){throw 'Base differs from independently observed initial pose; no motion sent'}
    $target=[double]$origin['b']+10*[math]::PI/180
    Record 'plan' @{origin=$origin;target_base_rad=$target;delta_deg=10;speed_steps_s=100;acc_100steps_s2=1;operator_workspace_confirmed_in_chat=$true}
    Send-Packet @{T=101;joint=1;rad=$target;spd=100;acc=1}
    $outboundConfirmed=Observe-Target $target
    if($outboundConfirmed){Start-Sleep -Milliseconds 700;$null=Get-Sample}
    # Return only after recent bounded feedback. No blind return on communication failure.
    Send-Packet @{T=101;joint=1;rad=[double]$origin['b'];spd=100;acc=1}
    $returnConfirmed=Observe-Target ([double]$origin['b'])
}catch{$failure=$_.Exception.Message;Record 'error' $failure}
finally{if($serial.IsOpen){$serial.Close()};$serial.Dispose();Record 'closed' 'No torque, home, reset or mode command; controller retains last target'}
$result=[ordered]@{port=$Port;device=$device.PNPDeviceID;motion_commands_sent=$motionCount;origin=$origin;outbound_target_rad=$target;last_feedback=$last;outbound_feedback_confirmed=$outboundConfirmed;return_feedback_confirmed=$returnConfirmed;error=$failure;output_dir=$outDir;scope='Stock USB micro-motion commissioning only; no payload experiment or full hardware qualification';source_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$result | ConvertTo-Json -Depth 8
if($failure -or -not $outboundConfirmed -or -not $returnConfirmed){exit 1}
