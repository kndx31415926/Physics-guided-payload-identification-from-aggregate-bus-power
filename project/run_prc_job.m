function run_prc_job(run_dir)
% Independent, resumable literature-method comparison worker.
root=fileparts(mfilename('fullpath'));
assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'prc:Snapshot','Use frozen source snapshot.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
if isempty(lock),channel.close();file.close();error('prc:Busy','Another worker owns this run.');end
cleanup=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PRC already complete; nothing changed.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;clock_start=tic;
phase='source_verification';
try
    publish('running','Verifying frozen code and original training inputs.');
    verify_manifest(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');
    verify_manifest(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    phase='training_data';publish('running','Load only original training and validation observations.');
    P=load(fullfile(spec.source_dir,'data_plan.mat'));
    pre=find(P.objects.split~="test");
    D=prc_build_dataset(spec.source_dir,fullfile(run_dir,'training_data.mat'),pre,cfg);
    prc_validate_dataset(D,P,pre);
    train=find(string(D.split)=="train");val=find(string(D.split)=="validation");
    assert(numel(train)==spec.train_budget&&numel(val)>=2,'prc:Split','Unexpected training split.');
    models_path=fullfile(run_dir,'models.mat');
    if isfile(models_path)
        S=load(models_path,'model','pe');model=S.model;pe=S.pe;
        fprintf('Restored complete literature models.\n');
    else
        phase='model_training';publish('running','Fit PE and literature-based T/TA models; validation-only epoch selection.');
        pe=prc_pe_fit(D,train,spec);
        [model,training_info]=prc_lao_train(D,train,val,spec,run_dir); %#ok<NASGU>
        pgar_model_atomic_save(models_path,struct('model',model,'pe',pe));
    end
    phase='selection_lock';publish('running','Freeze every model before new test observations are loaded.');
    selection=struct('schema','prc_selection_v1','locked_utc',utc(), ...
        'models_sha256',prc_file_hash(models_path),'spec',spec, ...
        'training_object_ids',D.object_id(train),'validation_object_ids',D.object_id(val), ...
        'holdout_dir',spec.holdout_dir,'test_loaded_for_selection',false);
    lock_path=fullfile(run_dir,'LOCKED_SELECTION_BEFORE_TEST.mat');
    if isfile(lock_path)
        L=load(lock_path,'selection');assert(strcmp(L.selection.models_sha256,selection.models_sha256));
        assert(isequaln(L.selection.spec,spec));selection=L.selection;
    else
        pgar_model_atomic_save(lock_path,struct('selection',selection));
        prc_write_json(fullfile(run_dir,'LOCKED_SELECTION_BEFORE_TEST.json'),selection);
    end
    phase='waiting_for_independent_data';publish('running','Models locked. Waiting for the independent data job to finish.');
    while ~isfile(fullfile(spec.holdout_dir,'COMPLETE.json'))
        if isfile(fullfile(spec.holdout_dir,'status.json'))
            data_status=jsondecode(fileread(fullfile(spec.holdout_dir,'status.json')));
            assert(~strcmp(data_status.state,'failed'),'prc:DataJobFailed','Independent data job failed; inspect its logs and Resume.');
        end
        pause(30);publish('running','Models locked; independent test data generation is still running.');
    end
    phase='test_evaluation';publish('running','Evaluate all frozen models on the same NEW test objects.');
    info=prc_evaluate(run_dir,cfg,spec,model,pe);
    finished=struct('run_id',spec.run_id,'completed_utc',utc(),'elapsed_this_invocation_s',toc(clock_start), ...
        'scope',spec.scope,'results',info);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),finished);
    phase='complete';publish('complete','All literature comparisons, frozen-model controls and paired test results saved.');
    fprintf('PRC COMPLETE: %.1f s this invocation.\n',toc(clock_start));
catch err
    prc_write_json(fullfile(run_dir,'FAILED.json'),struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc()));
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state, ...
            'phase',phase,'updated_utc',utc(),'matlab_pid',feature('getpid'),'message',message));
    end
end
function reset_path(root)
restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
end
function verify_manifest(manifest,base,field)
T=readtable(manifest,'TextType','string','Delimiter',',','ReadVariableNames',true, ...
    'VariableNamingRule','preserve','NumHeaderLines',0);
for i=1:height(T)
    path=char(T.(field)(i));if ~isempty(base),path=fullfile(base,path);end
    assert(strcmp(prc_file_hash(path),T.sha256(i)),'prc:ChangedInput','Changed file: %s',path);
end
end
function release(lock,channel,file)
try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end
end
function t=utc()
t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
end
