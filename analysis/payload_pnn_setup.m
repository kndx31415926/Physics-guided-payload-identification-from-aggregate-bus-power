function [S,paths,restorePath]=payload_pnn_setup(packageRoot)
% Load the compact feature dataset, saved models and their input identities.
% The returned onCleanup object must stay alive until the caller returns.
if nargin<1||isempty(packageRoot),packageRoot=fileparts(fileparts(mfilename('fullpath')));end
root=char(java.io.File(char(packageRoot)).getCanonicalPath());
paths=struct('root',root,'study',fullfile(root,'studies','pnn_large_training_20261031_v1'), ...
    'dataset',fullfile(root,'data','pnn','pnn_dataset.mat'));
paths.snapshot=fullfile(paths.study,'source_snapshot');
required={'MODEL_LOCK.json','EVALUATION_COMPLETE.json','TRAINING_CONTRACT.mat', ...
    'LOCKED_BEFORE_GENERATION.json','source_manifest.csv','model_bundle.mat','predictions.csv','summary.csv','spec.json'};
for k=1:numel(required),assert(isfile(fullfile(paths.study,required{k})),'payload:Missing','Missing %s.',required{k});end
assert(isfile(paths.dataset)&&isfile([paths.dataset '.manifest.json']),'payload:Missing','Missing exported feature dataset or manifest.');
manifest=jsondecode(fileread([paths.dataset '.manifest.json']));listing=dir(paths.dataset);
assert(strcmp(manifest.schema,'reviewer_pnn_export_v1')&&manifest.export_bytes==listing.bytes&& ...
    strcmp(manifest.export_sha256,payload_pnn_sha256(paths.dataset)),'payload:DataHash','The compact dataset differs from its export manifest.');
before=jsondecode(fileread(fullfile(paths.study,'LOCKED_BEFORE_GENERATION.json')));
assert(strcmp(before.source_manifest_sha256,payload_pnn_sha256(fullfile(paths.study,'source_manifest.csv'))), ...
    'payload:SourceManifest','Historical source manifest changed.');
sources=payload_pnn_read_csv(fullfile(paths.study,'source_manifest.csv'),'source_manifest');
% Verify the recorded MATLAB sources and any explicit distribution mapping.
sourceInfo=payload_verify_sources(sources,paths.snapshot,root);
rows=sourceInfo.original_matlab_rows;
previous=path;restorePath=onCleanup(@()path(previous));
addpath(paths.snapshot,fullfile(paths.snapshot,'src'),fullfile(paths.snapshot,'vendor','bdcl_v29'));
for name={'pnn_predict','pnn_model_hash','pnn_train'}
    assert(strcmpi(which(name{1}),fullfile(paths.snapshot,'src',[name{1} '.m'])), ...
        'payload:Path','Another %s shadows the packaged source.',name{1});
end
S=load(paths.dataset,'D','spec','cfg','provenance','feature_provenance','object_manifest','trial_manifest');
assert(isfield(S,'D')&&isfield(S,'spec')&&isfield(S,'provenance'),'payload:Dataset','Invalid export.');
D=S.D;N=size(D.theta,1);
assert(N==22000&&D.planned_n==N&&isequal(D.trial_id,(1:N).')&&numel(unique(D.object_id))==16000, ...
    'payload:Counts','Unexpected exported trial or object identities.');
assert(sum(string(D.split)=="train")==12000&&sum(string(D.split)=="validation")==2000&&sum(string(D.split)=="test")==8000, ...
    'payload:Splits','Unexpected split sizes.');
splitIDs={unique(D.object_id(string(D.split)=="train")),unique(D.object_id(string(D.split)=="validation")), ...
    unique(D.object_id(string(D.split)=="test"))};
assert(isequal(cellfun(@numel,splitIDs),[12000 2000 2000])&&isempty(intersect(splitIDs{1},splitIDs{2}))&& ...
    isempty(intersect(splitIDs{1},splitIDs{3}))&&isempty(intersect(splitIDs{2},splitIDs{3})), ...
    'payload:ObjectSplit','Object identities overlap splits.');
assert(height(S.trial_manifest)==N&&height(S.object_manifest)==16000&&height(S.feature_provenance)==N&& ...
    isequal(S.trial_manifest.trial_id,D.trial_id)&&isequal(S.trial_manifest.object_id,D.object_id)&& ...
    isequal(string(S.trial_manifest.split),string(D.split))&&isequal(string(S.trial_manifest.condition),string(D.condition))&& ...
    isequal(S.feature_provenance.trial_id,D.trial_id)&&isequal(string(S.feature_provenance.feature_sha256),D.feature_sha256), ...
    'payload:Identity','Exported manifests differ from feature rows.');
assert(isequaln(S.spec,jsondecode(fileread(fullfile(paths.study,'spec.json'))))|| ...
    strcmp(psv_hash(S.spec),psv_hash(jsondecode(fileread(fullfile(paths.study,'spec.json'))))), ...
    'payload:Spec','Exported specification differs.');
S.test=payload_pnn_subset(D,{'test'});S.development=payload_pnn_subset(D,{'train','validation'});
S.lock=jsondecode(fileread(fullfile(paths.study,'MODEL_LOCK.json')));
S.evaluation=jsondecode(fileread(fullfile(paths.study,'EVALUATION_COMPLETE.json')));
for name={'predictions.csv','summary.csv'}
    found=false;
    for k=1:numel(S.evaluation.outputs)
        parts=regexp(strrep(char(S.evaluation.outputs(k).path),'\','/'),'/','split');
        if strcmp(parts{end},name{1})
            assert(strcmp(payload_pnn_sha256(fullfile(paths.study,name{1})),S.evaluation.outputs(k).sha256), ...
                'payload:ReferenceHash','Changed reference %s.',name{1});found=true;
        end
    end
    assert(found,'payload:ReferenceHash','No historical output hash for %s.',name{1});
end
training=load(fullfile(paths.study,'TRAINING_CONTRACT.mat'),'contract');S.training_contract=training.contract;
assert(strcmp(S.lock.bundle_sha256,payload_pnn_sha256(fullfile(paths.study,'model_bundle.mat')))&& ...
    strcmp(S.lock.bundle_sha256,S.provenance.model_sha256)&&strcmp(S.lock.plan_signature,D.plan_signature)&& ...
    ~S.lock.selection_uses_test,'payload:ModelHash','Frozen model identity differs.');
assert(strcmp(S.evaluation.dataset_hash,S.provenance.source_dataset_hash)&& ...
    strcmp(S.training_contract.data_hash,S.provenance.development_dataset_hash), ...
    'payload:DatasetProvenance','Dataset hashes differ from historical manifests.');
% Byte hashes apply on every MATLAB release. Serialized value hashes are
% compared on the release recorded in the training configuration.
S.value_hashes=struct('test',pnn_model_hash(S.test),'development',pnn_model_hash(S.development), ...
    'original_release',S.training_contract.release,'current_release',version('-release'));
S.value_hashes.test_matches=strcmp(S.value_hashes.test,S.evaluation.dataset_hash);
S.value_hashes.development_matches=strcmp(S.value_hashes.development,S.training_contract.data_hash);
if strcmp(version('-release'),S.training_contract.release)
    assert(S.value_hashes.test_matches&&S.value_hashes.development_matches,'payload:ValueHash','Exported MATLAB dataset values differ from historical values.');
end
model=load(fullfile(paths.study,'model_bundle.mat'),'bundle');S.bundle=model.bundle;
assert(numel(S.bundle.methods)==9,'payload:Methods','Expected nine frozen methods.');
S.source_matlab_files_verified=sourceInfo.verified_files;S.source_distribution=sourceInfo;S.export_manifest=manifest;
end
