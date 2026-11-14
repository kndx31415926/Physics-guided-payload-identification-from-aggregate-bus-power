function report=pra_online_smoke(outdir,iterations)
% Development only: reuse six old TRAIN/VALIDATION records, never final test.
if nargin<1,outdir='C:/new/results/pra_online_development_smoke_v1';end
if nargin<2,iterations=3;end
if ~exist(outdir,'dir'),mkdir(outdir);end
root='C:/new/results/pgar_nominal_20261029_v1';
A=load(fullfile(root,'model_bundle.mat'),'bundle');cfg=A.bundle.cfg;
spec=struct('source_dir',root,'online_iterations',iterations,'online_validation_patience',30);
state=pra_online_init(cfg,spec);P=load(fullfile(root,'data_plan.mat'),'objects');
ids=[1 2 3 4 601 602];refs=struct([]);
for k=1:numel(ids)
    file=fullfile(root,'data',sprintf('trial_%06d.mat',ids(k)));
    if ~exist(file,'file'),file=fullfile(root,'trials',sprintf('trial_%06d.mat',ids(k)));end
    R=load(file,'record');o=P.objects(P.objects.object_id==ids(k),:);
    role='reference_train';if k>4,role='reference_validation';end
    v=struct('obs',R.record.obs,'known_theta',[o.mass_kg o.cx_m o.cz_m], ...
        'is_reference',true,'role',role,'record_key',sprintf('development_old_%06d',ids(k)), ...
        'record_hash',prc_file_hash(file));
    if isempty(refs),refs=v;else,refs(end+1)=v;end
end
eta=state.eta0;before=pra_online_predict(state,refs(1).obs,eta,'all');
assert(numel(before.methods)==7&&all([before.methods.available]),'pra:Smoke','Prediction availability.');
frozen=pgar_model_predict(A.bundle,refs(1).obs);
assert(max(abs(frozen.candidate_theta-before.methods(1).clipped))<1e-12,'pra:Smoke','Frozen mismatch.');
obs=refs(1).obs;obs.truth=struct('mass',999);obs.known_theta=[999 999 999];
changed=pra_online_predict(state,obs,eta,'all');
assert(isequaln(before,changed),'pra:Smoke','Predictions read forbidden truth metadata.');
[updated,update]=pra_online_update(state,refs(1:4),refs(5:6),eta,'development_block_01');
for name={'network_only','full','no_replay'}
    v=update.variants.(name{1});assert(v.trained&&numel(v.seed_reports)==3&& ...
        all([v.seed_reports.trained])&&~any(strcmp({v.seed_reports.reason},'training_failed')), ...
        'pra:Smoke','Training failed for %s.',name{1});
end
[again,repeated]=pra_online_update(updated,refs(1:4),refs(5:6),eta,'development_block_01');
assert(repeated.already_processed&&isequaln(again,updated),'pra:Smoke','Update is not idempotent.');
bad=refs(1:4);bad(1).role='unknown';role_rejected=false;
try,pra_online_update(updated,bad,refs(5:6),eta,'development_bad');
catch err,role_rejected=strcmp(err.identifier,'pra:ReferenceRole');end
assert(role_rejected,'pra:Smoke','Unknown role was accepted.');
% Known supervised references remain usable when the inverse teacher's
% heuristic deployment gate rejects; unknown deployment still rejects.
strict=state;strict.cfg.ident.max_fit_rmse_W=0;
strict.spec.online_iterations=2;
strict_prediction=pra_online_predict(strict,refs(1).obs,eta,'full');
assert(strict_prediction.available&&~strict_prediction.accepted, ...
    'pra:Smoke','Strict teacher gate did not reject unknown deployment.');
[~,strict_update]=pra_online_update(strict,refs(1:4),refs(5:6),eta,'development_strict_teacher');
assert(strict_update.variants.full.trained&&all(strict_update.variants.full.train_reference_usable)&& ...
    ~all(strict_update.variants.full.train_teacher_accepted), ...
    'pra:Smoke','Known references were incorrectly excluded by the unknown-load teacher gate.');
report=struct('scope','DEVELOPMENT_ONLY six old train/validation records; no test data', ...
    'passed',true,'frozen_matches_source',true,'truth_metadata_invariance',true, ...
    'unknown_role_rejected',role_rejected,'update_idempotent',true, ...
    'known_reference_teacher_gate_independent',true,'update',update,'strict_teacher_update',strict_update);
save(fullfile(outdir,'smoke.mat'),'report','-v7.3');
fprintf('PRA online smoke PASS. Nine candidate fits, %.2f seconds.\n',update.elapsed_s);
end
