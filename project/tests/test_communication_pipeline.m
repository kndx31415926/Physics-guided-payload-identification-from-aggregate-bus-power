function info=test_communication_pipeline(run_dir)
% Audit a completed frozen DEVELOPMENT run; no new training or trajectories.
assert(isfile(fullfile(run_dir,'COMPLETE.json')),'prt:TestIncomplete','Finish the development run first.');
S=load(fullfile(run_dir,'configuration.mat'),'cfg','spec');
assert(S.spec.development_fixture,'prt:TestFormal','This audit is for a development fixture.');
snapshot=fullfile(run_dir,'source_snapshot');addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'));
N=numel(S.spec.robust_ids);R=numel(S.spec.robust_seeds);total=N*(2+R);
records=dir(fullfile(run_dir,'trials','trial_*.mat'));
assert(numel(records)==N*(1+R),'Wrong number of new complete trajectories.');
paths=arrayfun(@(x)fullfile(x.folder,x.name),records,'UniformOutput',false);
before=cellfun(@prc_file_hash,paths,'UniformOutput',false);
P=readtable(fullfile(run_dir,'comm_predictions.csv'),'TextType','string');
assert(height(P)==total*52,'Missing planned predictions or model seeds.');
assert(numel(unique(P.method))==8,'Expected all eight frozen methods.');
baseline=readtable(fullfile('C:/new/results/pra_robust_20261030_v1','robust_predictions.csv'),'TextType','string');
baseline=baseline(baseline.condition=="nominal"&ismember(baseline.object_id,S.spec.robust_ids),:);
current=P(P.condition=="legacy_command20_encoder0",:);
keys={'object_id','method','model_seed','model_kind','postprocessing'};
baseline=sortrows(baseline,keys);current=sortrows(current,keys);
assert(isequaln(baseline(:,keys),current(:,keys)),'Baseline row identities differ.');
for name={'pred_mass_kg','pred_cx_m','pred_cz_m','finite_prediction','model_valid','accepted'}
    assert(isequaln(baseline.(name{1}),current.(name{1})),'Frozen baseline differs: %s.',name{1});
end
di=prt_generate_data(run_dir,S.cfg,S.spec);
ei=prt_evaluate(run_dir,S.cfg,S.spec);
assert(di.generated_this_call==0&&di.skipped_existing==N*(1+R),'Resume regenerated data.');
assert(ei.reused_checkpoints==total,'Resume recomputed predictions.');
assert(isequal(before,cellfun(@prc_file_hash,paths,'UniformOutput',false)),'Resume changed a trajectory file.');
again=readtable(fullfile(run_dir,'comm_predictions.csv'),'TextType','string');
assert(isequaln(P,again),'Resume changed predictions.');
summary=readtable(fullfile(run_dir,'comm_summary.csv'),'TextType','string');
selected=summary.condition=="jitter_command10to15_encoder10to15"&summary.method=="physics_residual_nn"& ...
    summary.model_kind=="ensemble"&summary.postprocessing=="raw";
Q=summary(selected,:);single=Q.jitter_seed~=-1;average=~single;
assert(sum(single)==R&&sum(average)==1&&Q.planned_objects(average)==N&&Q.planned_prediction_count(average)==N*R);
assert(abs(mean(Q.mass_mae_g(single))-Q.mass_mae_g(average))<1e-12,'Repeated predictions were improperly averaged.');
B=readtable(fullfile(run_dir,'comm_paired_differences.csv'),'TextType','string');
assert(height(B)==48&&all(B.planned_objects==N),'Paired tests lost planned methods or objects.');
bad=S.cfg;bad.sensor.power_std_W=bad.sensor.power_std_W+.001;rejected=false;
try,prt_generate_data(run_dir,bad,S.spec);catch err,rejected=strcmp(err.identifier,'prt:Config');end
assert(rejected,'Changed source configuration was not rejected.');
for k=1:numel(paths)
    V=load(paths{k},'record');r=V.record;
    assert(isempty(r.error)&&r.truth.physical_success&&all(r.obs.stationary),'Smoke trajectory failed.');
    c=r.truth.communication.command_packets;e=r.truth.communication.encoder_packets;
    assert(all(abs(c.applied_t-c.issued_t-c.applied_delay_s)<1e-10),'Incorrect actuator arrival time.');
    arrived=isfinite(e.receive_t);
    assert(all(abs(e.receive_t(arrived)-e.sample_t(arrived)-e.applied_delay_s(arrived))<1e-10),'Incorrect feedback arrival time.');
    assert(all(r.obs.communication.power_record_encoder_receive_t<=r.obs.t+1e-12),'Future feedback leaked.');
end
info=struct('passed',true,'development_fixture',true,'objects',N,'new_trajectories',numel(paths), ...
    'cases',total,'prediction_rows',height(P),'paired_rows',height(B),'baseline_exact_match',true, ...
    'resume_reused',ei.reused_checkpoints,'changed_configuration_rejected',true);
pgar_model_atomic_save(fullfile(run_dir,'PIPELINE_AUDIT_PASS.mat'),struct('info',info));
fprintf('COMMUNICATION PIPELINE AUDIT PASS: %d cases, %d predictions, exact baseline, resume and mismatch gates.\n',total,height(P));
end
