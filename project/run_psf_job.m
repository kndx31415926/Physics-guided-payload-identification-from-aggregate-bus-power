function run_psf_job(run_dir)
% Standalone immutable-snapshot worker; scheduled-task compatible.
root=fileparts(mfilename('fullpath'));assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'psf:Snapshot','Run the frozen snapshot.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
assert(~isempty(lock),'psf:Busy','Another worker owns this job.');cleanup=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('Matched steady-input diagnostic already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;phase='verification';started=tic;
try
    publish('running','Verifying source, plans and immutable inputs.');
    verify(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');verify(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    phase='training';publish('running','Train/validation fitting only; no evaluation observations loaded.');
    models=psf_train(run_dir,cfg,spec);
    phase='evaluation';publish('running','Locked models evaluated on reused development objects and timing conditions.');
    info=psf_evaluate(run_dir,cfg,spec,models);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),struct('run_id',spec.run_id,'completed_utc',utc(), ...
        'elapsed_this_invocation_s',toc(started),'study_role',spec.study_role,'development_fixture',true,'smoke_test',spec.smoke_test,'results',info));
    phase='complete';publish('complete','Matched steady-input development diagnostic complete.');
catch err
    prc_write_json(fullfile(run_dir,'FAILED.json'),struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc()));
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state,'phase',phase, ...
            'updated_utc',utc(),'matlab_pid',feature('getpid'),'development_fixture',true,'smoke_test',spec.smoke_test,'message',message));
    end
end
function reset_path(root),restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));end
function verify(file,base,field)
T=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');
for i=1:height(T),p=char(T.(field)(i));if ~isempty(base),p=fullfile(base,p);end
    assert(strcmp(prc_file_hash(p),T.sha256(i)),'psf:ChangedInput','Changed input: %s',p);
end
end
function release(lock,channel,file)
try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end
end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end
