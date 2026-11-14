# Offline only: extract named pure function definitions via AST. Never source
# the motion script, construct a port, execute its entry point, or change a flag.
$ErrorActionPreference='Stop'
$source='C:\new\scripts\roarm_shoulder_upright_rock_once.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Motion source does not parse'}
$names=@('Assert-Numeric','Assert-Limits','Assert-InitialFeedback','Assert-LoadProxy','Get-EnvelopeViolation','Get-StabilityWindow','Get-StageAssessment')
foreach($name in $names){
    $found=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($found.Count -ne 1){throw "Missing or ambiguous pure function $name"}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
$Fields=@('b','s','e','t');$Limits=@{b=@(-3.0,3.0);s=@(-1.5,1.5);e=@(-.7,3.05);t=@(1.15,5.12)}
$passed=0
function Require([bool]$Ok,[string]$Name){if(-not $Ok){throw "Offline assertion failed: $Name"};$script:passed++}
function Require-Throw([scriptblock]$Action,[string]$Name){$thrown=$false;try{& $Action}catch{$thrown=$true};Require $thrown $Name}
function Angles([double]$ShoulderDeg){return [ordered]@{b=0.0;s=($ShoulderDeg*[math]::PI/180);e=1.0;t=3.1}}
function Frames([double]$ShoulderDeg,[double]$Duration=2.0){
    $items=[Collections.Generic.List[object]]::new()
    for($at=0.0;$at -le $Duration+1e-9;$at+=.25){$items.Add([ordered]@{elapsed_s=$at;angles_rad=(Angles $ShoulderDeg);torS=0.0})}
    return ,$items
}
$center=Angles 0;$goal=Angles 2
Assert-InitialFeedback (Angles 5);Require $true 'near-zero positive edge accepted'
Assert-InitialFeedback (Angles -5);Require $true 'near-zero negative edge accepted'
Require-Throw {Assert-InitialFeedback (Angles 5.01)} 'outside near-zero interval rejected'
Assert-LoadProxy @{torS=599.0};Require $true 'proxy below threshold accepted'
Require-Throw {Assert-LoadProxy @{torS=600.0}} 'positive threshold rejected'
Require-Throw {Assert-LoadProxy @{torS=-600.0}} 'negative threshold rejected'
Require-Throw {Assert-LoadProxy @{torS=[double]::NaN}} 'nonfinite proxy rejected'
Require ([bool](Get-EnvelopeViolation (Angles -.36) $center $center $goal['s'] $true)) 'reverse beyond .35 rejected'
Require (-not (Get-EnvelopeViolation (Angles -.34) $center $center $goal['s'] $true)) 'subthreshold reversal remains bounded'
Require ([bool](Get-EnvelopeViolation (Angles 3.51) $center $center $goal['s'] $true)) 'segment plus1.5 rejected'
Require ([bool](Get-EnvelopeViolation (Angles 6.51) $center (Angles 5) 0.0 $true)) 'global6.5 rejected'
$inactive=Angles 0;$inactive['e']+=1.01*[math]::PI/180
Require ([bool](Get-EnvelopeViolation $inactive $center $center $goal['s'] $true)) 'inactive global drift rejected'
$a=Get-StageAssessment $center $goal $center (Frames 2) 2.0 0.0 $false $true
Require $a['passed'] 'settled actual plus2 accepted'
Require ([math]::Abs($a['allowed_target_error_deg']-.8) -lt 1e-9) 'first-stage adaptive tolerance .8'
$a=Get-StageAssessment $center $goal $center (Frames 0) 2.0 0.0 $false $true
Require (-not $a['passed']) 'stationary motor cannot pass'
$a=Get-StageAssessment $center $goal $center (Frames 1) 2.0 0.0 $false $true
Require (-not $a['passed']) '50percent alone cannot override adaptive target error'
$a=Get-StageAssessment $center $goal $center (Frames 2 1.0) 1.0 0.0 $false $true
Require (-not $a['passed']) 'short stable interval rejected'
$a=Get-StageAssessment $center $goal $center (Frames 2 4.25) 4.25 0.0 $false $true
Require (-not $a['passed']) 'late settled outcome rejected'
$a=Get-StageAssessment (Angles 1.3) (Angles 5) $center (Frames 5) 2.0 0.0 $false $false
Require ([math]::Abs($a['commanded_span_deg']-3.7) -lt 1e-9 -and $a['passed']) 'next span uses actual start not old target'
$a=Get-StageAssessment (Angles 4) $center $center (Frames 0) 2.0 0.0 $false $false
Require $a['passed'] 'signed return progress accepted only when measured'
[ordered]@{offline_only=$true;checks_passed=$passed;serial_opened=$false;stop_changed=$false;motion_script_sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}|ConvertTo-Json -Depth 3
