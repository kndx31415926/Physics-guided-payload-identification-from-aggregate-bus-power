function run_pnn_job(run_dir)
%RUN_PNN_JOB Frozen, independently scheduled development-to-test pipeline.
root=fileparts(mfilename('fullpath'));snapshot=fullfile(run_dir,'source_snapshot');
assert(strcmpi(char(java.io.File(root).getCanonicalPath()),char(java.io.File(snapshot).getCanonicalPath())), ...
    'pnn:Snapshot','Run from this experiment source_snapshot.');
reset_path(root);maxNumCompThreads(1); %#ok<MAXNCT>
file=java.io.RandomAccessFile(fullfile(run_dir,'pnn_job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
if isempty(lock),channel.close();file.close();error('pnn:Busy','Another worker owns this run.');end
cleanup=onCleanup(@()release_lock(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PNN already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));log_cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'),'cfg','spec');cfg=C.cfg;spec=C.spec;
P=load(fullfile(run_dir,'data_plan.mat'),'plan_signature');phase='verification';started=tic;
try
    publish('running',phase,'Checking immutable sources and run inputs.');
    before=jsondecode(fileread(fullfile(run_dir,'LOCKED_BEFORE_GENERATION.json')));
    assert(strcmp(before.source_manifest_sha256,prc_file_hash(fullfile(run_dir,'source_manifest.csv'))), ...
        'pnn:ManifestChanged','Frozen source manifest changed.');
    assert(strcmp(before.input_manifest_sha256,prc_file_hash(fullfile(run_dir,'input_manifest.csv'))), ...
        'pnn:ManifestChanged','Frozen input manifest changed.');
    verify_table(fullfile(run_dir,'source_manifest.csv'),snapshot,'relative_path');
    verify_table(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    phase='development_data';publish('running',phase,'Generating or verifying new training and validation trajectories.');
    pnn_generate_data(run_dir,cfg,spec,{'train','validation'});
    phase='development_features';publish('running',phase,'Caching observation-only features and all-eight-pose physical baseline.');
    D=pnn_cache_dataset(run_dir,cfg,spec,{'train','validation'});
    phase='training';publish('running',phase,'Training checkpointed models; validation selection only.');
    training=pnn_train(D,spec,run_dir);
    bundle_file=fullfile(run_dir,'model_bundle.mat');assert(isfile(bundle_file),'pnn:NoModel','Training did not produce model_bundle.mat.');
    model_lock=struct('schema','pnn_model_lock_v1','run_id',spec.run_id,'bundle_path',bundle_file, ...
        'bundle_sha256',prc_file_hash(bundle_file),'plan_signature',P.plan_signature, ...
        'selection_uses_test',false,'locked_utc',pnn_utc());
    lock_file=fullfile(run_dir,'MODEL_LOCK.json');
    if isfile(lock_file)
        old=jsondecode(fileread(lock_file));
        assert(strcmp(old.bundle_sha256,model_lock.bundle_sha256)&&strcmp(old.plan_signature,P.plan_signature)&&~old.selection_uses_test, ...
            'pnn:ModelChanged','Model or plan differs from lock.');
    else
        prc_write_json(lock_file,model_lock);
    end
    clear D
    phase='independent_test_data';publish('running',phase,'Models locked; generating paired new test objects in four conditions.');
    pnn_generate_data(run_dir,cfg,spec,{'test'});
    phase='independent_test_features';publish('running',phase,'Caching test observations under the same frozen feature rules.');
    Dtest=pnn_cache_dataset(run_dir,cfg,spec,{'test'});
    phase='independent_test_evaluation';publish('running',phase,'All methods evaluated with raw, clipped, coverage and paired statistics.');
    evaluation=pnn_evaluate(Dtest,spec,run_dir);
    complete=struct('schema',spec.schema,'run_id',spec.run_id,'completed_utc',pnn_utc(), ...
        'last_invocation_seconds',toc(started),'training',training,'evaluation',evaluation,'scope',spec.scope, ...
        'model_bundle_sha256',prc_file_hash(bundle_file),'plan_signature',P.plan_signature);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),complete);
    publish('complete','complete','Data, training, locked independent testing and paired summaries are complete.');
catch err
    failure=struct('run_id',spec.run_id,'phase',phase,'failed_utc',pnn_utc(), ...
        'identifier',err.identifier,'message',err.message,'stack',err.stack);
    failure_dir=fullfile(run_dir,'failures');if ~isfolder(failure_dir),mkdir(failure_dir);end
    id=char(java.util.UUID.randomUUID());prc_write_json(fullfile(failure_dir,[id '.json']),failure);
    prc_write_json(fullfile(run_dir,'FAILED.json'),failure);publish('failed',phase,err.message);
    fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,phase_name,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state, ...
            'phase',phase_name,'updated_utc',pnn_utc(),'matlab_pid',feature('getpid'),'message',message));
        fprintf('[%s] %s: %s\n',pnn_utc(),phase_name,message);
    end
end
function reset_path(root)
restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
end
function verify_table(file,base,path_column)
names={path_column,'sha256'};
if strcmp(path_column,'relative_path'),names{3}='bytes';end
options=delimitedTextImportOptions('NumVariables',numel(names));
options.DataLines=[2 Inf];options.Delimiter=',';options.VariableNames=names;
options.VariableTypes=repmat({'string'},1,numel(names));
T=readtable(file,options);
for k=1:height(T)
    pathname=char(T.(path_column)(k));if ~isempty(base),pathname=fullfile(base,pathname);end
    assert(isfile(pathname)&&strcmp(prc_file_hash(pathname),T.sha256(k)), ...
        'pnn:Integrity','Missing or changed frozen input/source: %s',pathname);
end
end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
