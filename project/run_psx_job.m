function run_psx_job(runDir,manualFormalAuthorization)
%RUN_PSX_JOB Manual-only isolated worker. Smoke completion never starts full.
if nargin<2,manualFormalAuthorization=false;end
snapshot=fileparts(mfilename('fullpath'));assert(strcmpi(snapshot,fullfile(runDir,'source_snapshot')),'psx:Snapshot','Run frozen snapshot.');
reset_path(snapshot);
maxNumCompThreads(1); %#ok<MAXNCT>
C=load(fullfile(runDir,'configuration.mat'),'spec');spec=C.spec;
assert(spec.smoke_test||isequal(manualFormalAuthorization,true),'psx:AwaitingAuthorization','Formal run requires a new explicit user instruction and manual authorization.');
fh=java.io.RandomAccessFile(fullfile(runDir,'job.lock'),'rw');ch=fh.getChannel();lk=ch.tryLock();
assert(~isempty(lk),'psx:Busy','Another worker owns the run.');cleanup=onCleanup(@()release(lk,ch,fh)); %#ok<NASGU>
diary(fullfile(runDir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
phase='integrity';
try
    verify(runDir,snapshot);
    if isfile(fullfile(runDir,'COMPLETE.json'))
        S=jsondecode(fileread(fullfile(runDir,'COMPLETE.json')));
        for k=1:numel(S.outputs)
            assert(strcmp(prc_file_hash(S.outputs(k).path),S.outputs(k).sha256),'psx:OutputChanged','Completed output changed.');
            if endsWith(S.outputs(k).path,'EVALUATION_COMPLETE.json')
                evaluation=jsondecode(fileread(S.outputs(k).path));
                for j=1:numel(evaluation.outputs)
                    assert(strcmp(prc_file_hash(evaluation.outputs(j).path),evaluation.outputs(j).sha256),'psx:OutputChanged','Completed evaluation artifact changed.');
                end
            end
        end
        publish('complete','complete','Verified existing completed smoke/study; no work repeated.');return
    end
    publish('running',phase,'Frozen sources and settings verified.');
    phase='development_read';publish('running',phase,'Read-only loading of frozen training and validation features.');
    [D,cfg,pnnSpec,oldBundle,sourceAudit]=psx_read_frozen(spec.source_run,spec.development_per_condition);
    save_new(fullfile(runDir,'source_audit.mat'),struct('audit',sourceAudit));
    phase='contract_checks';publish('running',phase,'Checking physical identities, loss controls and evaluation denominators.');
    checksFile=fullfile(runDir,'contract_checks.mat');
    if pnn_checkpoint('exists',checksFile),checks=pnn_checkpoint('read',checksFile);
    else
        checks=struct();checks.physics=contract_check('physics',@(~)pix_test_contracts());
        checks.evaluation=contract_check('evaluation',@(folder)psx_test_evaluation(folder));
        checks.learning=contract_check('learning',@(folder)pfl_test_models(folder));
        pnn_checkpoint('write',checksFile,checks);
    end
    phase='matched_training';publish('running',phase,'Matched-loss affine/nonlinear fits; smoke uses two epochs only.');
    mode='futurefull';if spec.smoke_test,mode='tinySmoke';end
    fairSpec=pfl_spec(oldBundle,mode);
    fairSpec.full_run_authorized=~spec.smoke_test&&isequal(manualFormalAuthorization,true);
    [training,fairBundle]=pfl_train(D,oldBundle,fairSpec,fullfile(runDir,'matched_training'));
    assert(training.complete,'psx:TrainingIncomplete','All matched candidates must finish before new test generation.');
    bundle=oldBundle;bundle.methods=[oldBundle.methods fairBundle.methods];
    bundle.supplement=struct('original_primary',oldBundle.primary_method,'fair_contract',training,'smoke_only',spec.smoke_test);
    modelFile=fullfile(runDir,'combined_bundle.mat');
    if ~pnn_checkpoint('exists',modelFile),pnn_checkpoint('write',modelFile,struct('bundle',bundle));
    else,S=pnn_checkpoint('read',modelFile);assert(strcmp(pnn_model_hash(S.bundle),pnn_model_hash(bundle)),'psx:ModelChanged','Combined models changed.');bundle=S.bundle;end
    modelHash=prc_file_hash(modelFile);lock=struct('bundle_sha256',modelHash,'selection_uses_test',false,'locked_utc',pnn_utc());
    lockFile=fullfile(runDir,'MODEL_LOCK.json');
    if isfile(lockFile),prior=jsondecode(fileread(lockFile));assert(strcmp(prior.bundle_sha256,modelHash));
    else,prc_write_json(lockFile,lock);end
    % No test objects/observations are generated above this model lock.
    options=struct('smoke_test',spec.smoke_test,'bootstrap_replicates',spec.bootstrap_replicates, ...
        'bootstrap_seed',spec.bootstrap_seed,'bounds',pnnSpec.bounds, ...
        'pairs',{{oldBundle.primary_method,'ridge13';oldBundle.primary_method,'ridgeAug';oldBundle.primary_method,'interactionRidge'; ...
        'nonlinear_fixed','affine_fixed';'nonlinear_selected','affine_selected'}});
    audits=struct();evaluations=struct();
    for panel={'original','independent'}
        phase=[panel{1} '_generation'];publish('running',phase,'New held-out probe episodes; sealed failures remain in the denominator.');
        [T,audits.(panel{1})]=psx_generate_panel(runDir,cfg,pnnSpec,spec,panel{1},modelHash);
        phase=[panel{1} '_evaluation'];publish('running',phase,'Raw/clip errors, coverage and explicit paired comparisons.');
        evaluations.(panel{1})=psx_evaluate(T,bundle,options,fullfile(runDir,[panel{1} '_evaluation']));
    end
    % Engineering acceptance has no error-magnitude or winner requirement.
    healthy=all([audits.original.rows.physical_success])&&all([audits.independent.rows.physical_success])&& ...
        all([audits.original.rows.stationary])&&all([audits.independent.rows.stationary])&& ...
        all([audits.original.rows.feature_usable])&&all([audits.independent.rows.feature_usable]);
    if spec.smoke_test,assert(healthy,'psx:SmokeNotHealthy','Pipeline finished but physical/feature smoke checks failed; inspect retained records.');end
    outputs=struct('path',{},'sha256',{});
    files={modelFile,fullfile(runDir,'original_simulation_audit.csv'),fullfile(runDir,'independent_simulation_audit.csv'), ...
        fullfile(runDir,'original_evaluation','EVALUATION_COMPLETE.json'),fullfile(runDir,'independent_evaluation','EVALUATION_COMPLETE.json')};
    for k=1:numel(files),outputs(k)=struct('path',files{k},'sha256',prc_file_hash(files{k}));end
    result=struct('run_id',spec.run_id,'completed_utc',pnn_utc(),'smoke_only',spec.smoke_test,'engineering_checks_healthy',healthy, ...
        'formal_run_started',~spec.smoke_test,'automatic_followup',false,'training',training,'evaluations',evaluations,'outputs',outputs);
    prc_write_json(fullfile(runDir,'COMPLETE.json'),result);
    publish('complete','complete','Supplement smoke/study completed. Formal work does not start automatically.');
catch err
    failure=struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'failed_utc',pnn_utc());
    folder=fullfile(runDir,'failures');if ~isfolder(folder),mkdir(folder);end
    prc_write_json(fullfile(folder,[char(java.util.UUID.randomUUID()) '.json']),failure);
    prc_write_json(fullfile(runDir,'FAILED.json'),failure);publish('failed',phase,err.message);rethrow(err)
end
    function publish(state,p,message)
        prc_write_json(fullfile(runDir,'status.json'),struct('state',state,'phase',p,'message',message,'smoke_test',spec.smoke_test, ...
            'matlab_pid',feature('getpid'),'updated_utc',pnn_utc()));fprintf('%s: %s\n',p,message);
    end
    function value=contract_check(name,action)
        file=fullfile(runDir,['check_' name '.mat']);
        if pnn_checkpoint('exists',file),saved=pnn_checkpoint('read',file);value=saved.report;return;end
        folder=fullfile(runDir,[name '_test_' char(java.util.UUID.randomUUID())]);
        value=action(folder);pnn_checkpoint('write',file,struct('report',value));
    end
end
function verify(runDir,snapshot)
L=jsondecode(fileread(fullfile(runDir,'PREPARED_LOCK.json')));
assert(strcmp(L.source_manifest_sha256,prc_file_hash(fullfile(runDir,'source_manifest.csv')))&& ...
    strcmp(L.configuration_sha256,prc_file_hash(fullfile(runDir,'configuration.mat')))&& ...
    strcmp(L.protocol_sha256,prc_file_hash(fullfile(runDir,'FROZEN_PROTOCOL.txt'))),'psx:FrozenChanged','Run settings changed.');
T=readtable(fullfile(runDir,'source_manifest.csv'),'Delimiter',',','ReadVariableNames',true,'TextType','string','VariableNamingRule','preserve');
for k=1:height(T),assert(strcmp(prc_file_hash(fullfile(snapshot,T.relative_path(k))),T.sha256(k)),'psx:FrozenChanged','Frozen source changed.');end
end
function reset_path(snapshot)
% restoredefaultpath is a script on Windows; use a non-nested workspace.
restoredefaultpath;
addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'),fullfile(snapshot,'tests'));
end
function save_new(file,value)
if ~pnn_checkpoint('exists',file),pnn_checkpoint('write',file,value);
else,prior=pnn_checkpoint('read',file);assert(isequaln(prior,value),'psx:SourceChanged','Previously read source identity changed.');end
end
function release(l,c,f)
try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end
end
