function info=test_psv_contracts()
% Model-input isolation and preregistered generator/statistical contracts.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root);cfg=startup_bpil();
probes=bpil_probe_library(cfg);C=psv_conditions(cfg,probes(2));
assert(numel(C)==4&&strcmp(C(1).id,'nominal')&&C(4).mechanical&&C(4).electrical);
[model,~]=bpil_make_plant(cfg,struct('mass',.15,'com',[.12 0 0]));tau=zeros(8,4);
for k=1:8,tau(k,:)=gravityTorque(model.robot,probes(2).poses(k,:));end
assert(all(psv_power_mismatch(tau,C(1))==0));
assert(abs(mean(psv_power_mismatch(tau,C(3)))-C(3).loss_reference_target_extra_W)<1e-12);
assert(isequal(psv_power_mismatch(-tau,C(3)),psv_power_mismatch(tau,C(3))));
modelpath=fullfile(root,'results','psf_steady_development_20261030_v1','models.mat');hash=prc_file_hash(modelpath);S=load(modelpath,'models');
P=load(fullfile(root,'results','prc_holdout_20261029_v1','trials','trial_000003.mat'),'record');
[a,f]=psv_predict(S.models,cfg,P.record.obs);obs=P.record.obs;obs.truth=[999 888 777];obs.theta_true=[0 0 0];obs.condition='combined_mismatch';obs.object_id=-123;
[b,g]=psv_predict(S.models,cfg,obs);assert(isequaln(a,b)&&isequaln(f,g),'psv:Leakage','Truth metadata changed inference.');
bad=obs;bad.stationary(1)=false;[b,~]=psv_predict(S.models,cfg,bad);assert(all(arrayfun(@(v)all(isnan(v.raw),'all'),b)),'psv:Failure','Unusable obs must remain unavailable.');
assert(strcmp(hash,prc_file_hash(modelpath)),'psv:Mutation','Frozen models changed.');
R=readtable(fullfile(root,'results','psf_steady_development_20261030_v1','predictions.csv'),'TextType','string');
R=R(R.train_budget==600&R.condition=="legacy_command20_encoder0"&R.model_seed==0&R.object_id<=5,:);R.condition(:)="nominal";
[pairs,I]=psv_bootstrap(R,struct('bootstrap_seed',1160991,'bootstrap_replicates',50));
assert(all(I.finite_pair_n==height(unique(R(:,{'object_id'}))))&&all(I.ci_lower<=I.ci_upper));
assert(all(pairs.paired_finite));
info=struct('pass',true,'checks',9,'scope','Prespecified power normalization, zero nominal perturbation, sign symmetry, model input isolation, failed input coverage and paired object bootstrap.');
fprintf('PSV CONTRACT TEST PASS: 9 checks.\n');
end
