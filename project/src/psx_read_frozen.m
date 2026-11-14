function [D,cfg,spec,bundle,audit]=psx_read_frozen(sourceRun,perCondition)
%PSX_READ_FROZEN Read sealed development rows without modifying the old run.
% Selection of a smoke subset uses split/condition/ID, never labels or error.
if nargin<2,perCondition=Inf;end
assert(isinf(perCondition)||(isscalar(perCondition)&&perCondition>=1&&perCondition==floor(perCondition)));
assert(isfile(fullfile(sourceRun,'COMPLETE.json')),'psx:SourceIncomplete','Source run is not complete.');
inputs=readtable(fullfile(sourceRun,'input_manifest.csv'),'Delimiter',',','ReadVariableNames',true,'TextType','string','VariableNamingRule','preserve');
for name=["configuration.mat","objects.csv","manifest.csv"]
    file=fullfile(sourceRun,name);ix=endsWith(replace(inputs.input_path,'\','/'),"/"+name);
    assert(sum(ix)==1&&strcmp(prc_file_hash(file),inputs.sha256(ix)),'psx:SourceIdentity','Source input changed: %s',name);
end
C=load(fullfile(sourceRun,'configuration.mat'),'cfg','spec');cfg=C.cfg;spec=C.spec;
lock=jsondecode(fileread(fullfile(sourceRun,'MODEL_LOCK.json')));modelFile=fullfile(sourceRun,'model_bundle.mat');
assert(~lock.selection_uses_test&&strcmp(prc_file_hash(modelFile),lock.bundle_sha256),'psx:SourceIdentity','Frozen model changed.');
S=load(modelFile,'bundle');bundle=S.bundle;
core={'pnn_predict','pnn_features','pnn_nn_fit','pnn_nn_predict','pnn_ridge_fit','pnn_ridge_predict','bpil_predict_power','pgar_model_features','bpil_teacher'};
for k=1:numel(core)
    frozen=fullfile(sourceRun,'source_snapshot','src',[core{k} '.m']);
    assert(strcmp(prc_file_hash(which(core{k})),prc_file_hash(frozen)),'psx:EstimatorChanged','Frozen inference/training function changed: %s',core{k});
end
M=readtable(fullfile(sourceRun,'manifest.csv'),'Delimiter',',','ReadVariableNames',true,'TextType','string','VariableNamingRule','preserve');
O=readtable(fullfile(sourceRun,'objects.csv'),'Delimiter',',','ReadVariableNames',true,'TextType','string','VariableNamingRule','preserve');ids=[];
for split=["train","validation"]
    for family=["nominal","mechanical","electrical","combined"]
        q=find(M.split==split&M.condition==family);q=q(1:min(numel(q),perCondition));ids=[ids;q]; %#ok<AGROW>
    end
end
ids=sort(ids);M=M(ids,:);N=height(M);
assert(~any(M.split=="test")&&N>0,'psx:TestLeakage','Only development rows may be loaded.');
D=struct('schema','pnn_dataset_v1','X13',nan(N,13),'Xaug',nan(N,52),'base',nan(N,3),'physics8',nan(N,3), ...
    'theta',nan(N,3),'usable',false(N,1),'accepted',false(N,1),'physics8accepted',false(N,1), ...
    'physics8usable',false(N,1),'physical_success',false(N,1),'feature_usable',false(N,1), ...
    'object_id',M.object_id,'trial_id',M.trial_id,'split',M.split,'condition',M.condition, ...
    'record_sha256',strings(N,1),'feature_sha256',strings(N,1));
paths=strings(N,1);hashes=paths;
for i=1:N
    paths(i)=fullfile(sourceRun,'feature_cache',sprintf('feature_%06d.mat',M.trial_id(i)));
    sealfile=paths(i)+".sha256.json";
    assert(isfile(sealfile)&&~isfile(paths(i)+".seal_pending.json"),'psx:UnsealedSource','Source needs separate recovery; reader will not repair it.');
    seal=jsondecode(fileread(sealfile));hashes(i)=prc_file_hash(paths(i));
    assert(strcmp(seal.sha256,hashes(i))&&strcmpi(seal.file,paths(i)),'psx:SourceIdentity','Changed source feature.');
    S=load(paths(i),'checkpoint');cp=S.checkpoint;F=cp.features;
    assert(cp.complete&&cp.key.trial_id==M.trial_id(i),'psx:SourceIdentity','Wrong feature trial.');
    oi=find(O.object_id==M.object_id(i));assert(isscalar(oi));
    D.theta(i,:)=[O.mass_kg(oi),O.cx_m(oi),O.cz_m(oi)];
    for f={'X13','Xaug','base','physics8'},D.(f{1})(i,:)=F.(f{1});end
    D.physical_success(i)=cp.physical_success;D.feature_usable(i)=F.usable;
    D.usable(i)=cp.physical_success&&F.usable;D.accepted(i)=cp.physical_success&&F.accepted;
    D.physics8accepted(i)=cp.physical_success&&F.physics8accepted;D.physics8usable(i)=cp.physical_success&&F.physics8usable;
    D.record_sha256(i)=string(cp.key.record_sha256);D.feature_sha256(i)=hashes(i);
end
assert(isempty(intersect(D.object_id(D.split=="train"),D.object_id(D.split=="validation"))),'psx:SplitLeakage','Overlapping development objects.');
D.planned_n=N;D.failed_n=sum(~D.usable);
audit=struct('source_run',sourceRun,'model_sha256',lock.bundle_sha256,'per_condition_limit',perCondition, ...
    'train_rows',sum(D.split=="train"),'validation_rows',sum(D.split=="validation"),'test_rows_read',0, ...
    'feature_paths',paths,'feature_sha256',hashes,'source_read_only',true);
end
