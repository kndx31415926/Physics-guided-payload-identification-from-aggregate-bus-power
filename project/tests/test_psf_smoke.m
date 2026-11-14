function info=test_psf_smoke(run_name)
% Short train/evaluate/resume pipeline test; not an accuracy benchmark.
if nargin<1,run_name='psf_smoke_20261030_v1';end
root=fileparts(fileparts(mfilename('fullpath')));addpath(root);startup_bpil();
options=struct('train_sizes',72,'network_seeds',630101,'layers',{{8}},'lambdas',.001, ...
    'iterations',3,'patience',2,'validation_limit',8,'evaluation_ids',[3 4],'development_fixture',true,'smoke_test',true);
run_dir=prepare_psf_run(run_name,options);
C=load(fullfile(run_dir,'configuration.mat'));models=psf_train(run_dir,C.cfg,C.spec);
assert(isfile(fullfile(run_dir,'LOCKED_SELECTION_BEFORE_EVALUATION.mat'))&&~models.test_used_for_selection);
info=psf_evaluate(run_dir,C.cfg,C.spec,models);R=readtable(fullfile(run_dir,'predictions.csv'),'TextType','string');
assert(info.planned_cases==10&&height(R)==120&&numel(unique(R.method))==6,'Incomplete evaluation denominators.');
assert(all(R.finite_prediction)&&all(R.physical_success),'Unexpected missing smoke predictions.');
selected=readtable(fullfile(run_dir,'selected_models.csv'),'TextType','string');
assert(height(selected)==5&&all(selected.trainable_regression_parameters>0)&& ...
    all(selected.all_candidate_fit_s(~selected.original_frozen_reference)>=0),'Model complexity/timing metadata missing.');
again=psf_train(run_dir,C.cfg,C.spec);same=psf_evaluate(run_dir,C.cfg,C.spec,again);
R2=readtable(fullfile(run_dir,'predictions.csv'),'TextType','string');assert(isequaln(R,R2)&&same.reused_checkpoints==10,'Resume changed predictions.');
P=load(fullfile(run_dir,'evaluation_plan.mat'));F=psf_load_case(P.evaluation(1,:),C.cfg,C.spec);
ref=models.reference{1,1};raw=predict(ref.model,F.physics.residual(:,ref.columns)).*C.spec.scale+F.physics.base;
Q=R(R.case_id==1&R.method=="physics_residual_nn"&R.postprocessing=="raw",:);
assert(max(abs(raw-[Q.pred_mass_kg Q.pred_cx_m Q.pred_cz_m]))<1e-12,'Reference model prediction differs.');
S=readtable(fullfile(run_dir,'summary.csv'),'TextType','string');A=S(S.jitter_seed==-1,:);B=S(S.condition=="jitter_command10to15_encoder10to15"&S.jitter_seed~=-1,:);
assert(all(A.planned_cases==6)&&all(A.replicate_count==3)&&height(B)==3*height(A),'Replicate counts differ.');
E=1000*abs([Q.pred_mass_kg-Q.true_mass_kg,Q.pred_cx_m-Q.true_cx_m,Q.pred_cz_m-Q.true_cz_m]);
pick=S(S.condition==Q.condition(1)&S.jitter_seed==Q.jitter_seed(1)&S.method==Q.method(1)&S.postprocessing=="raw",:);
assert(all([pick.mass_p95_g pick.cx_p95_mm pick.cz_p95_mm]>=E-1e-10)&& ...
    all([pick.mass_max_g pick.cx_max_mm pick.cz_max_mm]>=E-1e-10),'Component tail errors missing or invalid.');
empty=R(1,:);empty.finite_prediction=false;empty.accepted=false;empty.pred_mass_kg=NaN;empty.pred_cx_m=NaN;empty.pred_cz_m=NaN;
empty_summary=psf_summarize(empty);assert(isnan(empty_summary.mass_p95_g)&&isnan(empty_summary.planar_com_max_distance_mm)&&empty_summary.prediction_coverage==0);
info.pass=true;info.run_dir=run_dir;info.checks=9;pgar_model_atomic_save(fullfile(run_dir,'SMOKE_TEST_PASS.mat'),struct('info',info));
fprintf('PSF SMOKE PASS: %d cases, %d prediction rows; all 10 checkpoints reused.\n',info.planned_cases,height(R));
end
