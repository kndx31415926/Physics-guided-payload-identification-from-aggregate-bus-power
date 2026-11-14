function run_pgar_job(run_dir)
% Run the frozen data -> physics cache -> validation -> test pipeline.
% The Windows scheduled-task worker calls this from source_snapshot.
assert(nargin==1&&isfolder(run_dir),'pgar:RunDirectory','Provide the prepared absolute run directory.');
root=fileparts(mfilename('fullpath'));snapshot=fullfile(run_dir,'source_snapshot');
assert(strcmpi(char(java.io.File(root).getCanonicalPath()), ...
    char(java.io.File(snapshot).getCanonicalPath())), ...
    'pgar:Snapshot','Start the job from its frozen source_snapshot directory.');
reset_job_path(root);
maxNumCompThreads(1); %#ok<MAXNCT>
config=load(fullfile(run_dir,'configuration.mat'),'cfg','spec');cfg=config.cfg;spec=config.spec;
assert(strcmpi(cfg.root,snapshot),'pgar:Configuration','Saved configuration points to another snapshot.');
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();
lock=channel.tryLock();
if isempty(lock),channel.close();file.close();error('pgar:AlreadyRunning','Another process owns this job.');end
release=onCleanup(@()release_lock(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json'))
    fprintf('Job already complete. No records or models changed.\n');return
end
diary(fullfile(run_dir,'job.log'));log_cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
start=tic;fprintf('\nPGAR job/resume %s at %s; pid=%d\n',spec.run_id,utc(),feature('getpid'));
phase='source_verification';
try
    publish('running',phase,'Checking the frozen source manifest.');
    verify_sources(snapshot,fullfile(run_dir,'source_manifest.csv'));
    phase='data_generation';publish('running',phase,'Generating or resuming independent full-servo objects.');
    data_info=pgar_generate_data(run_dir,cfg,spec);
    data_only=isfield(spec,'job_kind')&&strcmp(spec.job_kind,'data_only');
    model_path='';
    if data_only
        training_info=struct('state','not_requested','reason','Independent held-out data generation only.');
    else
        phase='model_training';publish('running',phase,'Physics features, validation selection and locked test evaluation.');
        training_info=pgar_train_models(run_dir,cfg,spec);
        assert(isfile(fullfile(run_dir,'model_bundle.mat'))&&isfile(fullfile(run_dir,'summary.csv')), ...
            'pgar:MissingOutput','Training returned without the required model and summary.');
        model_path=fullfile(run_dir,'model_bundle.mat');
    end
    if isfield(training_info,'summary'),training_info=rmfield(training_info,'summary');end
    finished=struct('schema',spec.schema,'run_id',spec.run_id,'completed_utc',utc(), ...
        'last_invocation_seconds',toc(start),'data',data_info,'training',training_info, ...
        'scope',spec.scope,'model',model_path);
    write_json(fullfile(run_dir,'COMPLETE.json'),finished);
    if data_only
        publish('complete','complete','All independent held-out data saved; no models trained in this data-only job.');
    else
        publish('complete','complete','All data, model checkpoints, validation selection and test results saved.');
    end
    fprintf('PGAR COMPLETE in this invocation %.1f seconds: %s\n',toc(start),run_dir);
catch ME
    error_record=struct('run_id',spec.run_id,'failed_utc',utc(),'phase',phase, ...
        'identifier',ME.identifier,'message',ME.message,'stack',ME.stack);
    write_json(fullfile(run_dir,'FAILED.json'),error_record);
    publish('failed',phase,ME.message);
    fprintf(2,'%s\n',getReport(ME,'extended','hyperlinks','off'));rethrow(ME)
end

    function publish(state,current_phase,message)
        write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id, ...
            'state',state,'phase',current_phase,'updated_utc',utc(), ...
            'matlab_pid',feature('getpid'),'message',message));
    end
end
function reset_job_path(root)
% restoredefaultpath is a script on Windows; use a non-static workspace.
restoredefaultpath;
addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
end
function verify_sources(snapshot,manifest_path)
M=readtable(manifest_path,'TextType','string');
for i=1:height(M)
    path=fullfile(snapshot,M.relative_path(i));assert(isfile(path),'pgar:SourceMissing','Missing snapshot file: %s',path);
    fid=fopen(path,'rb');assert(fid>=0);data=fread(fid,Inf,'*uint8');fclose(fid);
    digest=java.security.MessageDigest.getInstance('SHA-256');digest.update(data);
    hash=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
    assert(strcmp(hash,M.sha256(i)),'pgar:SourceChanged','Frozen snapshot changed: %s',path);
end
end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
function value=utc()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
end
function write_json(path,value)
temp=[path '.tmp'];fid=fopen(temp,'w','n','UTF-8');assert(fid>=0);
fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));fclose(fid);movefile(temp,path,'f');
end
