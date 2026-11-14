function tests = test_identification
% Verification of inverse identification gates, not accuracy claims.
tests=functiontests(localfunctions);
end
function setupOnce(testCase)
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'src'));addpath(fullfile(root,'vendor','bdcl_v29'));
cfg=struct('legacy',bdclp_config());
cfg.payload=struct('dimensions_m',[.256 .06 .08]);
cfg.ident=struct('bounds',[.06 .25;.04 .20;-.025 .025], ...
    'power_sigma_W',.04,'max_condition',1e5,'min_scaled_singular_value',1e-4);
q=[-20 -55 40 -25;-10 -50 50 -15;0 -45 60 -5;10 -40 65 10; ...
    20 -35 55 25;10 -30 45 40;0 -40 50 20;-10 -50 45 0; ...
    5 -65 35 45;15 -25 65 -35;-15 -60 70 15;25 -35 35 55]*pi/180;
testCase.TestData.cfg=cfg;testCase.TestData.q=q;
testCase.TestData.eta=struct('coefficients',cfg.legacy.power.coefficients);
end
function testAnalyticSensitivity(testCase)
cfg=testCase.TestData.cfg;q=testCase.TestData.q;eta=testCase.TestData.eta;
t=[.15 .11 .009];[~,d]=bpil_predict_power(cfg,q,t,eta);fd=zeros(size(d.jacobian));
for k=1:3
    a=t;b=t;a(k)=a(k)+1e-6;b(k)=b(k)-1e-6;
    fd(:,k)=(bpil_predict_power(cfg,q,a,eta)-bpil_predict_power(cfg,q,b,eta))/2e-6;
end
verifyEqual(testCase,d.jacobian,fd,'AbsTol',2e-7);
end
function testRecoveryAndIndependentHoldout(testCase)
cfg=testCase.TestData.cfg;q=testCase.TestData.q;eta=testCase.TestData.eta;
truth=[.153 .117 .008];obs=observations(q,bpil_predict_power(cfg,q,truth,eta));
r=bpil_teacher(cfg,obs,eta,[.10 .16 -.01]);
verifyTrue(testCase,r.accepted,strjoin(r.diagnostics.reasons,','));
verifyEqual(testCase,r.theta,truth,'AbsTol',1e-6);
verifyLessThan(testCase,r.validation_rmse_W,1e-6);
changed=obs;changed.plateau_P(r.diagnostics.validation_rows)= ...
    changed.plateau_P(r.diagnostics.validation_rows)+.6;
v=bpil_teacher(cfg,changed,eta,[.10 .16 -.01]);
verifyFalse(testCase,v.accepted);
verifyEqual(testCase,v.theta,r.theta,'AbsTol',1e-10);
verifyTrue(testCase,ismember('heldout_residual_too_large',v.diagnostics.reasons));
end
function testRepeatedPoseCannotCreateEvidence(testCase)
cfg=testCase.TestData.cfg;eta=testCase.TestData.eta;
q=repmat(testCase.TestData.q(1,:),16,1);
obs=observations(q,bpil_predict_power(cfg,q,[.15 .12 0],eta));
r=bpil_teacher(cfg,obs,eta,[]);
verifyFalse(testCase,r.accepted);
verifyEqual(testCase,r.diagnostics.unique_pose_count,1);
verifyEqual(testCase,r.diagnostics.reasons,{'insufficient_independent_poses'});
end
function testUnknownPayloadCannotCalibrate(testCase)
cfg=testCase.TestData.cfg;eta=testCase.TestData.eta;q=testCase.TestData.q;
obs=observations(q,bpil_predict_power(cfg,q,[.15 .12 0],eta));
[updated,r]=bpil_calibrate_anchor(cfg,obs,eta);
verifyFalse(testCase,r.accepted);verifyEqual(testCase,updated,eta);
obs.is_anchor=true;obs.known_mass_kg=.15;
[updated,r]=bpil_calibrate_anchor(cfg,obs,eta);
verifyFalse(testCase,r.accepted);verifyEqual(testCase,updated,eta);
end
function testAnchorUpdatesOnlyDeclaredLosses(testCase)
cfg=testCase.TestData.cfg;eta=testCase.TestData.eta;q=testCase.TestData.q;
actual=eta;actual.coefficients(1)=2.3;actual.coefficients(3:5)=1.2*eta.coefficients(3:5);
obs=observations(q,bpil_predict_power(cfg,q,[0 .128 0],actual));
obs.is_anchor=true;obs.known_mass_kg=0;
[updated,r]=bpil_calibrate_anchor(cfg,obs,eta);
verifyTrue(testCase,r.accepted,strjoin(r.reasons,','));
verifyEqual(testCase,updated.coefficients([2 6:13]),eta.coefficients([2 6:13]));
verifyLessThan(testCase,r.validation_rmse_W,1e-6);
verifyGreaterThanOrEqual(testCase,min(updated.coefficients),0);
verifyEqual(testCase,r.parameterization,'common_scale_aux');
verifyEqual(testCase,r.fitted_parameters,[2.3 1.2],'AbsTol',1e-6);
verifyEqual(testCase,updated.coefficients(3:5),actual.coefficients(3:5),'AbsTol',1e-6);
end
function testPerAxisEmptyArmCalibrationRejectsWeakWristInformation(testCase)
cfg=testCase.TestData.cfg;cfg.ident.anchor_model='per_axis';
eta=testCase.TestData.eta;q=testCase.TestData.q;
actual=eta;actual.coefficients([1 3 4 5])=actual.coefficients([1 3 4 5]).*[1.1 .9 1.15 .8];
obs=observations(q,bpil_predict_power(cfg,q,[0 .128 0],actual));
obs.is_anchor=true;obs.known_mass_kg=0;
[updated,r]=bpil_calibrate_anchor(cfg,obs,eta);
verifyFalse(testCase,r.accepted);
verifyEqual(testCase,updated,eta);
verifyEqual(testCase,r.parameterization,'per_axis');
verifyTrue(testCase,ismember('anchor_coefficients_not_identifiable',r.reasons));
verifyGreaterThan(testCase,r.condition,1e5);
end
function testProbeSelectionRejectsRepeatedPoseInformation(testCase)
cfg=testCase.TestData.cfg;eta=testCase.TestData.eta;q=testCase.TestData.q;
probes(1)=struct('id','repeated','poses',repmat(q(1,:),size(q,1),1));
probes(2)=struct('id','varied','poses',q);
[probe,d]=bpil_select_probe(cfg,probes,[.15 .12 0],eta);
verifyEqual(testCase,probe.id,'varied');
verifyGreaterThan(testCase,d.minimum_singular_values(2),d.minimum_singular_values(1));
end
function obs=observations(q,p)
obs=struct('plateau_q',q,'plateau_P',p,'plateau_sd_P',zeros(size(p)), ...
    'stationary',true(size(p)),'probe_id','fixed_validation_fixture');
end
