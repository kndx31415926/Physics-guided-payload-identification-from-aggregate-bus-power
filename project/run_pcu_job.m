function run_pcu_job(run_dir)
% Task Scheduler worker with immutable source, inputs, records, checkpoints.
root=fileparts(mfilename('fullpath'));assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'pcu:Snapshot','Frozen source required.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
assert(~isempty(lock),'pcu:Busy','Another worker owns this run.');cl=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PCU already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;phase='verify';started=tic;
try
    publish('running','Checking frozen method, source and inputs.');
    verify(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');verify(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    phase='data';publish('running','Generating prespecified independent full-servo trajectories.');
    if isfile(fullfile(run_dir,'DATA_COMPLETE.json'))
        data=jsondecode(fileread(fullfile(run_dir,'DATA_COMPLETE.json')));
    else,data=pcu_generate_data(run_dir,cfg,spec);end
    phase='data_hashes';publish('running','Freezing complete raw records before evaluating updates.');
    pcu_freeze_records(run_dir);
    phase='online';publish('running','Unknown predictions before reference-gated updates and ablations.');
    info=pcu_run_online(run_dir,cfg,spec);info.data=data;
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),struct('run_id',spec.run_id,'completed_utc',utc(),'elapsed_this_invocation_s',toc(started),'development_fixture',spec.development_fixture,'results',info));
    phase='complete';publish('complete','All planned prospective results, costs and paired-stream intervals saved.');
catch err
    prc_write_json(fullfile(run_dir,'FAILED.json'),struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc()));
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state,'phase',phase,'updated_utc',utc(),'matlab_pid',feature('getpid'),'message',message));
    end
end
function reset_path(root),restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));end
function verify(file,base,key)
T=readtable(file,'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'VariableNamingRule','preserve');
for i=1:height(T),p=char(T.(key)(i));if ~isempty(base),p=fullfile(base,p);end;assert(strcmp(prc_file_hash(p),T.sha256(i)),'pcu:Hash','Changed %s',p);end
end
function release(lock,channel,file),try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end,end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end
