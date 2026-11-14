function report=pcr_test_core()
%PCR_TEST_CORE Short read-only development-fixture test; no full study.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
source=fullfile(root,'results','pra_continual_20261030_v1');
C=load(fullfile(root,'results','pcu_prospective_20261030_v1','configuration.mat'),'cfg','spec');
spec=C.spec;spec.pcr_ridge_source_file=fullfile(root,'results','psv_frozen_confirmation_20261030_v2','frozen_models.mat');
spec.gate_min_absolute_improvement=1e6;state=pcr_online_init(C.cfg,spec);
assert(numel(state.frozen_models)==1&&isequal(state.source_manifest.training_ids,(1:600).')&& ...
    isequal(state.source_manifest.validation_ids,(601:750).'),'pcr:Test','Initial partitions/model multiplicity mismatch.');
P=load(fullfile(source,'data_plan.mat'),'manifest');M=P.manifest;
B=M(string(M.scenario)=="stationary"&M.stream_index==1&M.block==1,:);
Q=B(string(B.role)=="eval",:);record=load_record(source,Q.trial_id(1));
prediction=pcr_predict(state,record.obs);f=pra_online_features(state,record.obs,state.eta0);
learner=state.frozen_models{1};direct=psf_ridge('predict',learner.model,f.residual(:,learner.columns)).*state.scale+f.base;
assert(isequaln(prediction.methods(1).raw,direct)&&size(prediction.methods(1).seed_raw,1)==1, ...
    'pcr:Test','Frozen inference differs from the actual PSF ridge.');
tainted=record.obs;tainted.theta_true=[99 88 77];tainted.truth=struct('payload',-123);tainted.object_id=-17;
assert(isequaln(prediction,pcr_predict(state,tainted)),'pcr:Test','Unknown truth changed inference.');
Q=B(string(B.role)=="anchor",:);a=load_record(source,Q.trial_id);anchor=a.obs;
anchor.is_anchor=true;anchor.known_mass_kg=0;
train=references(source,B,"reference_train");valid=references(source,B,"reference_validation");
[updated,event]=pcr_online_update(state,anchor,train,valid,'pcr_core_fixture');
for name={'gated_calibration','gated_full'}
    n=name{1};assert(~event.systems.(n).deployed&&event.systems.(n).rollback_preserved&& ...
        isequaln(state.systems.(n),updated.systems.(n)),'pcr:Test','Rejected candidate changed deployed model/calibration.');
end
assert(event.systems.gated_full.training.network_only.success&& ...
    numel(event.systems.gated_full.training.network_only.seed_reports)==1&& ...
    event.systems.gated_full.training.network_only.seed_reports.training_seed==0, ...
    'pcr:Test','A genuine deterministic ridge fit did not complete.');
assert(numel(updated.replay)==4&&all(strcmp({updated.replay.role},'reference_train')), ...
    'pcr:Test','Validation references entered replay.');
% Changed validation labels may alter selection scores, never fitted coefficients.
other=valid;other(1).known_theta=other(1).known_theta+[.001 .002 .0001];
[~,changed]=pcr_online_update(state,anchor,train,other,'pcr_core_changed_validation');
fit1=event.systems.gated_full.training.network_only.fit;fit2=changed.systems.gated_full.training.network_only.fit;
assert(strcmp(fit1.model_sha256,fit2.model_sha256)&&~fit1.validation_targets_used, ...
    'pcr:Test','Validation labels changed ridge fitting.');
[again,repeated]=pcr_online_update(updated,anchor,train,valid,'pcr_core_fixture');
assert(repeated.already_processed&&isequaln(again,updated),'pcr:Test','Repeated identical update is not idempotent.');
bad=train;bad(1).known_theta(1)=bad(1).known_theta(1)+.0001;failed=false;
try,pcr_online_update(updated,anchor,bad,valid,'pcr_core_fixture');catch e,failed=strcmp(e.identifier,'pcr:BlockIdentity');end
assert(failed,'pcr:Test','Changed repeated-key label was silently ignored.');
badanchor=anchor;badanchor.plateau_P(1)=badanchor.plateau_P(1)+.01;failed=false;
try,pcr_online_update(updated,badanchor,train,valid,'pcr_core_fixture');catch e,failed=strcmp(e.identifier,'pcr:BlockIdentity');end
assert(failed,'pcr:Test','Changed repeated-key anchor was silently ignored.');
failed=false;try,pcr_online_update(updated,anchor,train,valid,'same_records_new_key');catch e,failed=strcmp(e.identifier,'pcr:ReferenceLeakage');end
assert(failed,'pcr:Test','Same records were reused under a new block key.');
bad=train;bad(1).role='eval';failed=false;
try,pcr_online_update(state,anchor,bad,valid,'bad_role');catch e,failed=strcmp(e.identifier,'pcr:ReferenceRole');end
assert(failed,'pcr:Test','Unknown-role labels entered fitting.');
report=struct('passed',true,'groups',12,'initial_parity',state.initial_parity, ...
    'training_ids_exact',true,'validation_ids_exact',true,'fit',fit1, ...
    'scope','Read-only prior development records; forced rejection; no research performance evaluation.');
fprintf('PCR core contracts passed: 12 groups.\n');
end
function r=load_record(source,id)
A=load(fullfile(source,'trials',sprintf('trial_%06d.mat',id)),'record');r=A.record;
end
function refs=references(source,B,role)
Q=B(string(B.role)==role,:);refs=struct([]);
for i=1:height(Q)
    r=load_record(source,Q.trial_id(i));file=fullfile(source,'trials',sprintf('trial_%06d.mat',r.trial_id));
    one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role), ...
        'record_key',sprintf('development/trial_%06d',r.trial_id),'record_hash',prc_file_hash(file));
    if isempty(refs),refs=one;else,refs(end+1)=one;end
end
end
