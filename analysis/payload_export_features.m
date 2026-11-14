function info=payload_export_features(runDir,outputFile)
% Consolidate recorded feature data into a compact dataset.
% payload_export_features(originalRunDir, '<build>/exports/pnn_dataset.mat')
% Check record seals, filenames and object identities before export.
runDir=char(java.io.File(char(runDir)).getCanonicalPath());outputFile=char(outputFile);
assert(isfile(fullfile(runDir,'COMPLETE.json')),'payload:Incomplete','PNN source run is not complete.');
assert(~isfile(outputFile)&&~isfile([outputFile '.manifest.json']),'payload:Exists','Choose a new export path.');
dest=char(java.io.File(outputFile).getCanonicalPath());
assert(~startsWith(lower(dest),[lower(runDir) filesep]),'payload:SourceWrite','Export must be outside the source run.');
snapshot=fullfile(runDir,'source_snapshot');oldpath=path;cleanup=onCleanup(@()path(oldpath)); %#ok<NASGU>
addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'));
assert(strcmpi(which('pnn_model_hash'),fullfile(snapshot,'src','pnn_model_hash.m')),'payload:Path','Wrong frozen source on path.');

inputs=payload_pnn_read_csv(fullfile(runDir,'input_manifest.csv'),'input_manifest');
for k=1:height(inputs)
    name=leaf(inputs.input_path(k));file=fullfile(runDir,name);
    assert(isfile(file)&&strcmp(payload_pnn_sha256(file),inputs.sha256(k)),'payload:InputHash','Changed source input %s.',name);
end
source=payload_pnn_read_csv(fullfile(runDir,'source_manifest.csv'),'source_manifest');
packageRoot=fileparts(fileparts(mfilename('fullpath')));
payload_verify_sources(source,snapshot,packageRoot);
before=jsondecode(fileread(fullfile(runDir,'LOCKED_BEFORE_GENERATION.json')));
assert(strcmp(before.input_manifest_sha256,payload_pnn_sha256(fullfile(runDir,'input_manifest.csv')))&& ...
    strcmp(before.source_manifest_sha256,payload_pnn_sha256(fullfile(runDir,'source_manifest.csv'))),'payload:Manifest','Historical manifest mismatch.');
C=load(fullfile(runDir,'configuration.mat'),'cfg','spec');cfg=C.cfg;spec=C.spec;
P=load(fullfile(runDir,'data_plan.mat'));
if isfield(P,'plan'),P=P.plan;end
assert(strcmp(P.plan_signature,before.plan_signature),'payload:Plan','Plan signature differs.');
M=P.manifest;O=P.objects(M.object_index,:);N=height(M);
assert(N==22000&&height(P.objects)==16000&&isequal(M.trial_id,(1:N).'),'payload:Count','Unexpected PNN plan.');
assert(sum(string(M.split)=="train")==12000&&sum(string(M.split)=="validation")==2000&&sum(string(M.split)=="test")==8000, ...
    'payload:Count','Unexpected split counts.');
names={'pnn_features','pnn_physics8','pgar_model_features','bpil_teacher','bpil_predict_power','bpil_static_design','bpil_hefting_features'};
hashes=struct();for k=1:numel(names),hashes.(names{k})=payload_pnn_sha256(which(names{k}));end
source_signature=psv_hash(hashes);
D=struct('schema','pnn_dataset_v1','plan_signature',P.plan_signature,'source_signature',source_signature, ...
    'X13',nan(N,13),'Xaug',nan(N,52),'base',nan(N,3),'physics8',nan(N,3), ...
    'theta',[O.mass_kg O.cx_m O.cz_m],'usable',false(N,1),'accepted',false(N,1), ...
    'physics8accepted',false(N,1),'physics8usable',false(N,1),'physical_success',false(N,1), ...
    'feature_usable',false(N,1),'object_id',M.object_id,'trial_id',M.trial_id,'split',string(M.split), ...
    'condition',string(M.condition),'record_sha256',strings(N,1),'feature_sha256',strings(N,1));
historical_path=strings(N,1);sidecar_sha256=strings(N,1);file_bytes=zeros(N,1);
for j=1:N
    name=sprintf('feature_%06d.mat',M.trial_id(j));file=fullfile(runDir,'feature_cache',name);
    sidecar=[file '.sha256.json'];assert(isfile(file)&&isfile(sidecar)&&~isfile([file '.seal_pending.json']), ...
        'payload:Missing','Missing, unsealed or pending feature %s.',name);
    seal=jsondecode(fileread(sidecar));listing=dir(file);h=payload_pnn_sha256(file);
    assert(strcmp(seal.schema,'pnn_atomic_sha256_v1')&&strcmp(leaf(seal.file),name)&& ...
        listing.bytes==seal.bytes&&strcmp(h,seal.sha256),'payload:FeatureSeal','Feature seal failed: %s.',name);
    S=load(file,'checkpoint');assert(isfield(S,'checkpoint'),'payload:Feature','Missing checkpoint.');cp=S.checkpoint;
    assert(cp.complete&&strcmp(cp.key.schema,'pnn_feature_checkpoint_v1')&&cp.key.trial_id==M.trial_id(j)&& ...
        strcmp(cp.key.plan_signature,P.plan_signature)&&strcmp(cp.key.extractor_signature,source_signature), ...
        'payload:FeatureIdentity','Feature identity failed at trial %d.',M.trial_id(j));
    assert(~isempty(regexp(char(cp.key.record_sha256),'^[0-9a-f]{64}$','once')),'payload:RecordHash','Invalid historical record hash.');
    F=cp.features;assert(isequal(size(F.X13),[1 13])&&isequal(size(F.Xaug),[1 52])&& ...
        isequal(size(F.base),[1 3])&&isequal(size(F.physics8),[1 3]),'payload:Shape','Feature shape differs.');
    D.X13(j,:)=F.X13;D.Xaug(j,:)=F.Xaug;D.base(j,:)=F.base;D.physics8(j,:)=F.physics8;
    D.physical_success(j)=cp.physical_success;D.feature_usable(j)=F.usable;
    D.usable(j)=F.usable&&cp.physical_success;D.accepted(j)=F.accepted&&cp.physical_success;
    D.physics8accepted(j)=F.physics8accepted&&cp.physical_success;
    D.physics8usable(j)=F.physics8usable&&cp.physical_success;
    D.record_sha256(j)=string(cp.key.record_sha256);D.feature_sha256(j)=string(h);
    historical_path(j)=string(seal.file);sidecar_sha256(j)=string(payload_pnn_sha256(sidecar));file_bytes(j)=listing.bytes;
    if mod(j,1000)==0,fprintf('PNN feature export %d/%d verified.\n',j,N);end
end
D.feature_names=feature_names();D.failed_n=sum(~D.usable);D.planned_n=N;
Dtest=payload_pnn_subset(D,{'test'});Ddev=payload_pnn_subset(D,{'train','validation'});
evaluation=jsondecode(fileread(fullfile(runDir,'EVALUATION_COMPLETE.json')));
assert(strcmp(pnn_model_hash(Dtest),evaluation.dataset_hash),'payload:TestIdentity','Exported test dataset differs from original evaluation hash.');
training=load(fullfile(runDir,'TRAINING_CONTRACT.mat'),'contract');
assert(strcmp(pnn_model_hash(Ddev),training.contract.data_hash),'payload:DevelopmentIdentity','Exported train/validation dataset differs from training hash.');
eligible=logical(Ddev.usable(:))&all(isfinite([Ddev.X13 Ddev.Xaug Ddev.base Ddev.theta]),2);
assert(isequaln(Ddev.object_id(eligible&string(Ddev.split)=="train"),training.contract.train_ids)&& ...
    isequaln(Ddev.object_id(eligible&string(Ddev.split)=="validation"),training.contract.validation_ids), ...
    'payload:Eligibility','Exported eligible object identities differ.');
lock=jsondecode(fileread(fullfile(runDir,'MODEL_LOCK.json')));
assert(strcmp(lock.bundle_sha256,payload_pnn_sha256(fullfile(runDir,'model_bundle.mat')))&&strcmp(lock.plan_signature,D.plan_signature), ...
    'payload:Model','Frozen model identity differs.');
feature_provenance=table(D.trial_id,historical_path,D.feature_sha256,sidecar_sha256,file_bytes, ...
    'VariableNames',{'trial_id','historical_feature_path','feature_sha256','sidecar_sha256','bytes'});
provenance=struct('schema','reviewer_pnn_export_v1','source_run',runDir,'created_utc',utc(), ...
    'source_input_manifest_sha256',before.input_manifest_sha256,'source_manifest_sha256',before.source_manifest_sha256, ...
    'source_dataset_hash',evaluation.dataset_hash,'development_dataset_hash',training.contract.data_hash, ...
    'model_sha256',lock.bundle_sha256,'plan_signature',D.plan_signature,'feature_records_verified',N, ...
    'raw_trajectories_loaded',0,'new_simulations',0,'models_trained',0, ...
    'scope','Observation-derived features with record hashes and object/trial identities.', ...
    'exporter_sha256',payload_pnn_sha256([mfilename('fullpath') '.m']));
object_manifest=P.objects;trial_manifest=M; %#ok<NASGU>
parent=fileparts(outputFile);if ~isfolder(parent),mkdir(parent);end
save(outputFile,'D','spec','cfg','provenance','feature_provenance','object_manifest','trial_manifest','-v7.3');
info=provenance;info.export_file=leaf(outputFile);info.export_sha256=payload_pnn_sha256(outputFile);
listing=dir(outputFile);info.export_bytes=listing.bytes;info.split_trials=[12000 2000 8000];info.split_objects=[12000 2000 2000];
write_json([outputFile '.manifest.json'],info);
fprintf('PNN_EXPORT_COMPLETE %s (%d bytes)\n',outputFile,listing.bytes);
end
function name=leaf(value)
v=char(value);parts=regexp(strrep(v,'\','/'),'/','split');name=parts{end};
end
function names=feature_names()
names=["base_mass_scaled","base_cx_scaled","base_cz_scaled",compose("residual_pose_%d",1:8),"teacher_fit_rmse","teacher_holdout_rmse"];
for k=1:8,for j=1:3,names(end+1)=string(sprintf('J_pose_%d_parameter_%d',k,j));end,end %#ok<AGROW>
names=[names compose("power_sd_pose_%d",1:8),compose("GN_parameter_%d",1:3),compose("log_singular_%d",1:3),"log_condition"];
end
function write_json(file,value)
assert(~isfile(file),'payload:Exists','Refusing to overwrite %s.',file);fid=fopen(file,'w','n','UTF-8');
assert(fid>=0,'payload:Write','Cannot create output.');c=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));
end
function s=utc(),s=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end
