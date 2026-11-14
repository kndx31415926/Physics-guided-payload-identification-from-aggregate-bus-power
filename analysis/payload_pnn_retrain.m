function report=payload_pnn_retrain(packageRoot,outputDir,executeTraining,resumeTraining)
% Fit estimators using the supplied training and validation features.
% Plan: payload_pnn_retrain(packageRoot)
% Start: payload_pnn_retrain(packageRoot,newOutputDir,true,false)
% Resume manually: payload_pnn_retrain(packageRoot,sameOutputDir,true,true)
if nargin<1||isempty(packageRoot),packageRoot=fileparts(fileparts(mfilename('fullpath')));end
if nargin<2,outputDir='';end
if nargin<3,executeTraining=false;end
if nargin<4,resumeTraining=false;end
assert(islogical(executeTraining)&&isscalar(executeTraining)&&islogical(resumeTraining)&&isscalar(resumeTraining), ...
    'payload:Argument','executeTraining and resumeTraining must be scalar logicals.');
assert(~resumeTraining||~isempty(outputDir),'payload:ResumeDirectory','Resume requires the original explicit output directory.');
[S,paths,restorePath]=payload_pnn_setup(packageRoot); %#ok<ASGLU>
Ddev=S.development;spec=S.spec;
assert(~any(string(Ddev.split)=="test")&&size(Ddev.theta,1)==14000,'payload:Split','Only 12000 train and 2000 validation rows may enter fitting.');
expectedContract=training_contract(Ddev,spec);contractHash=pnn_model_hash(expectedContract);
if strcmp(version('-release'),S.training_contract.release)
    assert(isequaln(expectedContract,S.training_contract),'payload:ContractConstruction', ...
        'Portable training contract differs from the original contract on its original release.');
end
report=struct('schema','payload_pnn_retrain_v2','executed',false,'resume_requested',resumeTraining, ...
    'already_complete',false,'training_trials',12000,'validation_trials',2000,'test_trials_supplied_to_training',0, ...
    'new_simulations',0,'raw_trajectories_loaded',0,'source_export_sha256',S.export_manifest.export_sha256, ...
    'source_dataset_value_hash',pnn_model_hash(Ddev),'original_release',S.training_contract.release, ...
    'current_release',version('-release'),'expected_training_contract_sha256',contractHash, ...
    'description','Feature-based training with the specified grids and seeds. Selection uses the validation split.', ...
    'reproducibility','Optimizer trajectories depend on MATLAB release and numerical environment. Saved-model inference supplies the reference predictions.');
if ~executeTraining
    fprintf('TRAINING PLAN: 12000 training and 2000 validation objects.\n');
    fprintf('Start with (...,newOutputDir,true,false); resume manually with (...,sameOutputDir,true,true).\n');
    return
end
outputDir=checked_directory(paths,S,outputDir);
identity=struct('schema','payload_pnn_training_identity_v1','output_directory',outputDir, ...
    'original_model_sha256',S.lock.bundle_sha256,'export_sha256',S.export_manifest.export_sha256, ...
    'development_value_sha256',pnn_model_hash(Ddev),'source_manifest_sha256',S.provenance.source_manifest_sha256, ...
    'specification_value_sha256',pnn_model_hash(spec),'training_contract_sha256',contractHash, ...
    'matlab_release',version('-release'),'plan_signature',Ddev.plan_signature);
identityHash=psv_hash(identity);requestFile=fullfile(outputDir,'PAYLOAD_TRAINING_REQUEST.json');
completionFile=fullfile(outputDir,'FEATURE_RETRAIN_COMPLETE.json');
if resumeTraining
    assert(isfolder(outputDir)&&isfile(requestFile),'payload:ResumeOrigin','Resume requires this wrapper''s PAYLOAD_TRAINING_REQUEST.json.');
    request=jsondecode(fileread(requestFile));
    assert(isfield(request,'identity')&&isfield(request,'identity_sha256')&& ...
        strcmp(request.identity_sha256,identityHash)&&strcmp(psv_hash(request.identity),identityHash), ...
        'payload:ResumeIdentity','Request differs in model, data, source, specification, release or output path.');
    assert(isfield(request,'specification')&&strcmp(psv_hash(request.specification),psv_hash(jsondecode(jsonencode(spec)))), ...
        'payload:ResumeSpecification','The human-readable request specification differs.');
    verify_contract(outputDir,expectedContract);
    [complete,info]=completed_result(outputDir,expectedContract,isfile(completionFile));
    if complete
        report.already_complete=true;report.training_result=info;report.request_identity_sha256=identityHash;
        if isfile(completionFile)
            previous=jsondecode(fileread(completionFile));
            assert(isfield(previous,'request_identity_sha256')&&strcmp(previous.request_identity_sha256,identityHash)&& ...
                strcmp(previous.training_result.model_sha256,info.model_sha256), ...
                'payload:CompletedIdentity','Completion report differs from the verified request/model.');
        end
        fprintf('Completed training found; using the saved result.\n');
        return
    end
else
    assert(~isfolder(outputDir)&&~isfile(outputDir),'payload:Exists','Initial training requires a new directory; resume must be explicit.');
    [ok,msg]=mkdir(outputDir);assert(ok,'payload:Output','%s',msg);
    request=struct('schema','payload_pnn_training_request_v1','created_utc',utc(), ...
        'identity',identity,'identity_sha256',identityHash,'specification',spec, ...
        'source_run_provenance',S.provenance.source_run,'selection_uses_test',false);
    payload_pnn_write_json(requestFile,request);
end
% A second process must not train in the same derivative directory.
session=javaObject('java.io.RandomAccessFile',fullfile(outputDir,'PAYLOAD_TRAINING_SESSION.lock'),'rw');
channel=session.getChannel();
try,lock=channel.tryLock();catch err,channel.close();session.close();rethrow(err);end
if isempty(lock),channel.close();session.close();error('payload:TrainingBusy','Another process owns this training directory.');end
sessionCleanup=onCleanup(@()release_lock(lock,channel,session)); %#ok<NASGU>
if resumeTraining
    verify_contract(outputDir,expectedContract);
    % Another invocation may have completed between the first read and lock.
    [complete,info]=completed_result(outputDir,expectedContract,isfile(completionFile));
    if complete
        if isfile(completionFile)
            previous=jsondecode(fileread(completionFile));
            assert(isfield(previous,'request_identity_sha256')&&strcmp(previous.request_identity_sha256,identityHash)&& ...
                strcmp(previous.training_result.model_sha256,info.model_sha256), ...
                'payload:CompletedIdentity','Completion report differs from the verified request/model.');
        end
        report.already_complete=true;report.training_result=info;report.request_identity_sha256=identityHash;
        fprintf('Completed training found; using the saved result.\n');return
    end
end
clear S
callerRng=rng;restoreRng=onCleanup(@()rng(callerRng)); %#ok<NASGU>
[info,bundle]=pnn_train(Ddev,spec,outputDir);
assert(info.complete&&numel(bundle.methods)==9&&strcmp(bundle.contract_hash,contractHash), ...
    'payload:Training','Training did not produce the complete matching nine-method bundle.');
[complete,verifiedInfo]=completed_result(outputDir,expectedContract,true);
assert(complete&&strcmp(verifiedInfo.model_sha256,info.model_sha256),'payload:Training','Completed model identity differs.');
report.executed=true;report.training_result=verifiedInfo;report.completed_utc=utc();report.request_identity_sha256=identityHash;
payload_pnn_write_json(completionFile,report);
end
function contract=training_contract(D,spec)
% Same field order, eligible rows and source list as frozen pnn_train.
eligible=logical(D.usable(:))&all(isfinite([D.X13 D.Xaug D.base D.theta]),2);
tr=find(string(D.split)=="train"&eligible);va=find(string(D.split)=="validation"&eligible);
names={'pnn_train','pnn_predict','pnn_nn_fit','pnn_nn_predict','pnn_ridge_fit','pnn_ridge_predict', ...
    'pnn_model_atomic_save','pnn_model_hash','pnn_model_load','pnn_model_exists','pnn_checkpoint','prc_file_hash'};
hashes=struct('name',{},'sha256',{});
for k=1:numel(names),hashes(k)=struct('name',names{k},'sha256',payload_pnn_sha256(which(names{k})));end
contract=struct('schema','pnn_training_contract_v1','spec',spec,'data_hash',pnn_model_hash(D), ...
    'train_ids',D.object_id(tr),'validation_ids',D.object_id(va),'source_hashes',hashes, ...
    'release',version('-release'),'eligibility','usable and finite X13/Xaug/base/theta; rejected teachers retained');
end
function verify_contract(outputDir,expected)
[saved,~,~]=read_generation(fullfile(outputDir,'TRAINING_CONTRACT.mat'));
assert(isfield(saved,'contract')&&isequaln(saved.contract,expected),'payload:ResumeContract','A matching sealed training contract is required for resume.');
end
function [complete,info]=completed_result(outputDir,expected,required)
complete=false;info=struct();modelFile=fullfile(outputDir,'model_bundle.mat');selectionFile=fullfile(outputDir,'LOCKED_SELECTION_BEFORE_TEST.mat');
if ~isfile(modelFile)||~isfile(selectionFile)
    assert(~required,'payload:Incomplete','Completion metadata exists but model or selection lock is missing.');return
end
[model,modelSeal,modelCommitted]=read_generation(modelFile);
[selected,selectionSeal,selectionCommitted]=read_generation(selectionFile);
if ~(modelCommitted&&selectionCommitted)
    assert(~required,'payload:Incomplete','Completed models require committed seals.');return
end
assert(strcmp(payload_pnn_sha256(modelFile),modelSeal.sha256)&& ...
    strcmp(payload_pnn_sha256(selectionFile),selectionSeal.sha256)&&isfield(model,'bundle')&&isfield(selected,'lock'), ...
    'payload:CompletedModel','Completed model/selection mirror differs from its sealed generation.');
bundle=model.bundle;selection=selected.lock;expectedHash=pnn_model_hash(expected);
assert(numel(bundle.methods)==9&&strcmp(bundle.contract_hash,expectedHash)&& ...
    strcmp(selection.contract_hash,expectedHash)&&strcmp(selection.bundle_sha256,modelSeal.sha256)&& ...
    ~bundle.selection_uses_test&&~selection.selection_uses_test&& ...
    isequal(bundle.training_object_ids,expected.train_ids)&&isequal(bundle.validation_object_ids,expected.validation_ids), ...
    'payload:CompletedModel','Completed model or selection identity differs.');
info=struct('complete',true,'modelpath',modelFile,'contract_hash',expectedHash,'model_sha256',modelSeal.sha256);complete=true;
end
function [payload,seal,committed]=read_generation(file)
% Read-only validation, including a pending precommit. The frozen trainer
% performs any recovery only after an explicitly requested resume.
folder=[file '.generations'];assert(isfolder(folder),'payload:ResumeContract','Missing sealed generations for %s.',file);
entries=dir(fullfile(folder,'generation_*.mat*'));numbers=[];
for k=1:numel(entries)
    token=regexp(entries(k).name,'^generation_(\d+)\.mat','tokens','once');
    if ~isempty(token),numbers(end+1)=str2double(token{1});end %#ok<AGROW>
end
numbers=sort(unique(numbers),'descend');message='No valid generation found.';
for number=numbers
    candidate=fullfile(folder,sprintf('generation_%08d.mat',number));
    try
        committed=isfile([candidate '.sha256.json']);pending=isfile([candidate '.seal_pending.json']);
        assert(xor(committed,pending),'payload:Seal','Expected exactly one committed or pending seal.');
        if committed,sealFile=[candidate '.sha256.json'];else,sealFile=[candidate '.seal_pending.json'];end
        seal=jsondecode(fileread(sealFile));
        assert(strcmp(seal.schema,'pnn_atomic_sha256_v1')&&strcmpi(seal.file,candidate),'payload:Seal','Generation seal identity differs.');
        source=candidate;
        if ~isfile(source)&&pending
            source=seal.temporary;assert(strcmpi(fileparts(source),folder),'payload:Seal','Pending data escaped its generation directory.');
        end
        listing=dir(source);assert(isscalar(listing)&&listing.bytes==seal.bytes&&strcmp(payload_pnn_sha256(source),seal.sha256), ...
            'payload:Seal','Generation bytes or SHA256 differ.');
        payload=load(source);return
    catch err,message=err.message;end
end
error('payload:NoValidGeneration','Cannot validate %s: %s',file,message);
end
function directory=checked_directory(paths,S,directory)
if isempty(directory),directory=fullfile(paths.root,'outputs',['pnn_feature_refit_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);end
directory=char(java.io.File(char(directory)).getCanonicalPath());
allowed=char(java.io.File(fullfile(paths.root,'outputs')).getCanonicalPath());
assert(~inside(directory,paths.root)||inside(directory,allowed),'payload:SourceWrite', ...
    'Training inside the package is permitted only under outputs.');
assert(~strcmpi(directory,allowed),'payload:SourceWrite','Choose a child directory under outputs.');
protected={paths.study,paths.snapshot,fullfile(paths.root,'data'),fullfile(paths.root,'analysis'), ...
    char(S.provenance.source_run),char(S.cfg.root)};
for k=1:numel(protected)
    % Historical host paths are compared only, never used to load files.
    value=protected{k};if ~ispc&&~isempty(regexp(value,'^[A-Za-z]:[\\/]','once')),continue,end
    value=char(java.io.File(value).getCanonicalPath());
    assert(~inside(directory,value)&&~inside(value,directory),'payload:SourceWrite','Output overlaps a protected source location.');
end

end
function yes=inside(candidate,parent)
yes=strcmpi(candidate,parent)||startsWith(lower(candidate),[lower(parent) filesep]);
end
function release_lock(lock,channel,session)
try,lock.release();catch,end;try,channel.close();catch,end;try,session.close();catch,end
end
function text=utc(),text=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end
