# Offline regression: exercise actual cleanup blocks with an in-memory serial fake.
# Does not load the executable script bodies, query devices, or open any port.
$ErrorActionPreference='Stop'
class RoArmCleanupSerialFake {
    [bool]$IsOpen=$true
    [bool]$Disposed=$false
    [bool]$FailClose=$false
    [Collections.Generic.List[string]]$Writes=[Collections.Generic.List[string]]::new()
    [void] WriteLine([string]$packet){$this.Writes.Add($packet)}
    [void] Close(){if($this.FailClose){throw 'injected close failure'};$this.IsOpen=$false}
    [void] Dispose(){$this.Disposed=$true;$this.IsOpen=$false}
}
$results=@()
foreach($name in @('roarm_hold_current_joint.ps1','roarm_empty_gripper_test.ps1','roarm_postcal_elbow_test.ps1')){
    $path=Join-Path 'C:\new\scripts' $name
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Parse error in ${name}: $errors"}
    $tries=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $null -ne $_.Finally})
    if($tries.Count -ne 1){throw "Expected one main cleanup block in $name"}
    $body=$tries[0].Finally.Extent.Text
    $cleanup=[scriptblock]::Create($body.Substring(1,$body.Length-2))
    foreach($scenario in @('success','position_error','uncertain_write','log_error','close_error','unavailable_port')){
        $result=& {
            param($cleanup,$scenario,$name)
            $serial=[RoArmCleanupSerialFake]::new()
            $serial.FailClose=($scenario -eq 'close_error')
            if($scenario -eq 'unavailable_port'){$serial.IsOpen=$false}
            $success=($scenario -eq 'success');$failure=if($success){$null}else{'injected failure'}
            $motionAttempted=$true;$script:motionAttempted=$true
            $motionCount=if($scenario -eq 'uncertain_write'){0}else{1}
            $releaseAttempted=$false;$releaseHostWritten=$false;$releaseError=$null
            function Record([string]$kind,$value){if($scenario -eq 'log_error'){throw 'injected log failure'}}
            try{. $cleanup}catch{if($scenario -ne 'close_error'){throw}}
            if($serial.Writes.Count -ne 0){throw "$name $scenario sent a cleanup command"}
            if(-not $serial.Disposed){throw "$name $scenario did not dispose serial"}
            [ordered]@{script=$name;scenario=$scenario;cleanup_writes=0;disposed=$true;passed=$true}
        } $cleanup $scenario $name
        $results+=,$result
    }
}
$results | ConvertTo-Json -Depth 4
