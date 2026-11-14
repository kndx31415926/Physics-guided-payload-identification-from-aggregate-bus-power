function info=test_pra_robustness_smoke(run_name)
% Development-only fixture; not an accuracy benchmark.
if nargin<1,run_name='pra_robustness_development_smoke_v1';end
root='C:/new';addpath(root);cfg=startup_bpil();
spec=struct('source_dir',fullfile(root,'results','pgar_nominal_20261029_v1'), ...
    'lao_dir',fullfile(root,'results','prc_lao_comparison_20261029_v3'), ...
    'robust_source_dir',fullfile(root,'results','pgar_pipeline_smoke_v2'), ...
    'robust_ids',[11 12],'robust_seeds',[910101 910102 910103], ...
    'robust_conditions',pra_perturb_observation('conditions'));
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'pra:SmokeExists','Choose a new smoke name.');mkdir(run_dir);
S=load(fullfile(spec.robust_source_dir,'trials','trial_000011.mat'),'record');obs=S.record.obs;
C=spec.robust_conditions;before=rng;
[nominal,meta]=pra_perturb_observation(obs,cfg,C(1),1);assert(isequaln(before,rng),'RNG state leaked.');
for field={'t','q','P','q_command','plateau_q','plateau_P','plateau_sd_P','stationary'}
    assert(isequaln(obs.(field{1}),nominal.(field{1})),'Nominal changed %s.',field{1});
end
noisy=pra_perturb_observation(obs,cfg,C(3),912345);again=pra_perturb_observation(obs,cfg,C(3),912345);
assert(isequaln(noisy,again),'Noise is not deterministic.');
assert(~isequaln(noisy.P,obs.P)&&~isequaln(noisy.plateau_P,obs.plateau_P),'Noise did not reach summaries.');
assert(isequaln(noisy.q,obs.q)&&isequaln(noisy.q_command,obs.q_command),'Power noise altered encoders/commands.');
coarse=pra_perturb_observation(obs,cfg,C(9),1);quantum=2*pi/1024;
assert(max(abs(coarse.q/quantum-round(coarse.q/quantum)),[],'all')<1e-10,'Coarse encoder is not quantized.');
biased=pra_perturb_observation(obs,cfg,C(11),1);
assert(max(abs((biased.q(:,2:4)-obs.q(:,2:4))-(2*pi/4096)*[1 -1 1]),[],'all')<1e-14,'Pitch bias mismatch.');
assert(isequaln(biased.q_command,obs.q_command),'Readout bias changed commands.');
P=pra_frozen_predict('load',cfg,spec);a=pra_frozen_predict(P,obs);
tainted=obs;tainted.truth=struct('mass',999,'q',rand(4));tainted.theta=[999 -99 888];tainted.object_id=777;
b=pra_frozen_predict(P,tainted);assert(isequaln(a.methods,b.methods),'Forbidden label fields changed inference.');
same=pra_frozen_predict(P,obs,struct('coefficients',cfg.legacy.power.coefficients));
assert(isequaln(a.methods,same.methods),'Explicit nominal eta changed inference.');
bundle=load(fullfile(spec.source_dir,'model_bundle.mat'),'bundle');deployed=pgar_model_predict(bundle.bundle,obs);
j=find(strcmp({a.methods.name},'physics_residual_nn'));
assert(max(abs(deployed.candidate_theta-a.methods(j).ensemble_clipped))<1e-12,'Frozen PGAR mismatch.');
unavailable=pra_frozen_predict(P,struct());assert(all(arrayfun(@(m)~any(m.finite)&&~any(m.accepted),unavailable.methods)),'Invalid readings accepted.');
info=pra_robustness(run_dir,cfg,spec);
first=readtable(fullfile(run_dir,'robust_predictions.csv'),'TextType','string');
summary=readtable(fullfile(run_dir,'robust_summary.csv'),'TextType','string');
again_info=pra_robustness(run_dir,cfg,spec);
second=readtable(fullfile(run_dir,'robust_predictions.csv'),'TextType','string');
assert(isequaln(first,second)&&again_info.reused_checkpoints==36,'Resume modified predictions or skipped checkpoints.');
assert(info.planned_object_condition_replicates==36&&height(first)==1872,'Unexpected complete prediction count.');
selected=summary.condition=="power_noise_0p15"&summary.method=="physics_residual_nn"& ...
    summary.model_kind=="ensemble"&summary.postprocessing=="raw";
Q=summary(selected,:);individual=Q.perturbation_seed~=-1;average=~individual;
assert(sum(individual)==3&&sum(average)==1&&Q.planned_objects(average)==2&&Q.planned_prediction_count(average)==6);
assert(abs(mean(Q.mass_mae_g(individual))-Q.mass_mae_g(average))<1e-12,'Noise replicates did not average errors.');
info.scope='DEVELOPMENT ONLY: 2 reused smoke-test objects, 12 conditions, 36 cases, checkpoint resume and isolation checks.';
pgar_model_atomic_save(fullfile(run_dir,'SMOKE_TEST_PASS.mat'),struct('info',info));
fprintf('PRA ROBUSTNESS SMOKE PASS: %d rows, %d summary rows, all 36 checkpoints reused.\n',height(first),height(summary));
end
