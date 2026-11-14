function fixture=pgar_model_smoke_fixture(root,cfg)
%PGAR_MODEL_SMOKE_FIXTURE DEVELOPMENT ONLY: copy old objects to test the API.
% This is deliberately not an independent scientific confirmation dataset.
% Returns a small specification; the caller explicitly invokes training.
if nargin<2,cfg=startup_bpil();end
assert(~exist(root,'dir'),'pgar:FixtureExists','Use a fresh development fixture directory.');
mkdir(root);mkdir(fullfile(root,'trials'));
oldroot=fullfile(cfg.root,'results','servo_signal_study_v2');
old=readtable(fullfile(oldroot,'objects.csv'),'TextType','string');
oldids=[(1:12) (73:76) (97:100)];
objects=old(oldids,:);objects.object_id=(1:height(objects)).';
spec=struct('train_sizes',[6 12],'network_seeds',630101,'layers',{{8}}, ...
    'lambdas',.001,'iterations',10,'patience',3,'scale',[.14 .14 .036], ...
    'bootstrap_n',100,'deployment_train_size',12,'probe_id','probe_02','study_role','DEVELOPMENT_ONLY', ...
    'scope','DEVELOPMENT ONLY: reused old simulation objects; never report as formal confirmation.');
pgar_model_atomic_save(fullfile(root,'data_plan.mat'),struct('objects',objects,'cfg',cfg,'spec',spec));
for i=1:height(objects)
    a=load(fullfile(oldroot,'trials',sprintf('trial_%03d.mat',oldids(i))),'record');
    record=a.record;record.object_id=i;record.trial_id=i;record.split=char(objects.split(i));
    pgar_model_atomic_save(fullfile(root,'trials',sprintf('trial_%06d.mat',i)),struct('record',record));
end
fixture=struct('root',root,'cfg',cfg,'spec',spec,'source_object_ids',oldids, ...
    'scope',spec.scope);
pgar_model_atomic_save(fullfile(root,'DEVELOPMENT_ONLY.mat'),struct('fixture',fixture));
end
