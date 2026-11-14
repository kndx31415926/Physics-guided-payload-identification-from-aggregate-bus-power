param([Parameter(Mandatory=$true)][string]$Port,[ValidateRange(3,30)][int]$Queries=3,[switch]$ReadSupply)
$ErrorActionPreference='Stop'
# Read-only stock-firmware commissioning. No motion, reset or torque command.
$device=Get-CimInstance Win32_SerialPort | Where-Object DeviceID -eq $Port
if(-not $device -or $device.PNPDeviceID -ne 'USB\VID_10C4&PID_EA60\8E1996E6427FEF119BB0181CEDD322A4'){throw 'Exact commissioned CP210x device required'}
$outDir=Join-Path 'C:\new\results\hardware_control' ('usb_supply_probe_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outDir | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $outDir 'executed_script.ps1')
$logPath=Join-Path $outDir 'serial.jsonl'
$clock=[Diagnostics.Stopwatch]::StartNew()
$received=[Collections.Generic.List[object]]::new()
$baseFeedback=[Collections.Generic.List[object]]::new()
$serial=[IO.Ports.SerialPort]::new($Port,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake=[IO.Ports.Handshake]::None
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$serial.ReadTimeout=200
$serial.WriteTimeout=1000
$serial.NewLine="`n"
$pending=''
$rxCharacters=0
function Write-Record([string]$Kind,[string]$Text){
    $entry=[ordered]@{elapsed_s=$clock.Elapsed.TotalSeconds;kind=$Kind;raw=$Text}
    $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $logPath -Encoding utf8
}
function Convert-FeedbackLine([string]$Line){
    # A 1051 packet may contain cached angles after a servo acquisition failure.
    # Reject the error before considering any returned angles a usable reference.
    if($Line -match 'status:\s*failed|Servo ID[^\r\n]*failed|rst:|boot:'){
        throw ('Controller acquisition failure or restart: '+$Line)
    }
    try{$obj=$Line | ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{return}
    if($null -eq $obj -or $obj -isnot [System.Collections.IDictionary]){return}
    if($obj['T'] -eq 1005 -and $obj['status'] -eq 0){
        throw ('Servo acquisition failed: '+$Line)
    }
    if($obj['T'] -eq 1001){$script:baseFeedback.Add($obj);return}
    if($obj['T'] -ne 1051){return}
    foreach($key in @('b','s','e','t','x','y','z')){
        $value=$obj[$key]
        if(-not $obj.Contains($key) -or $null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -isnot [ValueType] -or -not [double]::IsFinite([double]$value)){
            throw ('Invalid feedback field: '+$key)
        }
    }
    return $obj
}
function Receive-For([double]$Seconds){
    $deadline=$clock.Elapsed.TotalSeconds+$Seconds
    while($clock.Elapsed.TotalSeconds -lt $deadline){
        if($serial.BytesToRead -gt 0){
            $chunk=$serial.ReadExisting()
            $script:rxCharacters += $chunk.Length
            $script:pending += $chunk
            if($script:pending.Length -gt 32768){throw 'Receive buffer overflow'}
            while($script:pending.Contains("`n")){
                $idx=$script:pending.IndexOf("`n")
                $line=$script:pending.Substring(0,$idx).TrimEnd("`r")
                $script:pending=$script:pending.Substring($idx+1)
                Write-Record 'rx' $line
                # Keep uppercase T and lowercase t distinct; never swallow device errors.
                $obj=Convert-FeedbackLine $line
                if($null -ne $obj){$received.Add($obj)}
            }
        }
        Start-Sleep -Milliseconds 10
    }
}
$failure=$null
try{
    $serial.Open()
    Write-Record 'open' '115200 8N1; DTR=false RTS=false; no reset requested'
    Receive-For 2
    if($ReadSupply){
        # Audited General Driver T130 emits baseInfoFeedback only; standalone M2 may ignore it.
        # Do not equate absent response with a supply fault; v, if present, is cached.
        $bootPacket='{"T":130}'
        Write-Record 'tx_attempt' $bootPacket
        $serial.WriteLine($bootPacket)
        Receive-For 1
    }
    for($query=0;$query -lt $Queries;$query++){
        $packet='{"T":105}'
        Write-Record 'tx_attempt' $packet
        $serial.WriteLine($packet)
        Receive-For 1
    }
}catch{$failure=$_.Exception.Message;Write-Record 'error' $failure}
finally{
    if($script:pending.Length -gt 0){Write-Record 'rx_unterminated' $script:pending}
    if($serial.IsOpen){$serial.Close()}
    $serial.Dispose()
    Write-Record 'closed' 'Host port closed; no reset, torque or motion command sent'
}
$summary=[ordered]@{base_feedback_count=$baseFeedback.Count;base_feedback=@($baseFeedback.ToArray());supply_query_requested=[bool]$ReadSupply;voltage_freshness_verified=$false;supply_current_not_requested_or_assumed=$true;port=$Port;device=$device.PNPDeviceID;baud=115200;motion_commands_sent=0;rx_characters=$rxCharacters;feedback_count=$received.Count;feedback=@($received.ToArray());error=$failure;output_dir=$outDir;stock_feedback_not_acquisition_verified=$true;reference_eligible=($null -eq $failure -and $received.Count -ge $Queries);source_sha256=(Get-FileHash -LiteralPath (Join-Path $outDir 'executed_script.ps1') -Algorithm SHA256).Hash}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 10
if($failure){exit 1}
