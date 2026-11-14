function run_prb_job(run_dir)
% Independent scheduled worker for immutable joint-system development.
root=fileparts(mfilename('fullpath'));
assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'prb:Snapshot','Run frozen source only.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
assert(~isempty(lock),'prb:Busy','Another worker owns this run.');clean=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PRB already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;phase='source_verification';started=tic;
try
    publish('running','Verifying immutable code and read-only development inputs.');
    verify(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');verify(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    phase='development_replay';publish('running','Scoring unknown objects before whole-system reference gates.');
    info=prb_run_online(run_dir,cfg,spec);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),struct('run_id',spec.run_id,'completed_utc',utc(), ...
        'elapsed_this_invocation_s',toc(started),'development_fixture',true,'results',info));
    phase='complete';publish('complete','Development replay and audits saved; fresh confirmation still required.');
catch err
    prc_write_json(fullfile(run_dir,'FAILED.json'),struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc()));
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(status,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',status,'phase',phase, ...
            'updated_utc',utc(),'matlab_pid',feature('getpid'),'message',message));
    end
end
function reset_path(root),restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));end
function verify(file,base,field)
T=readtable(file,'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0);
for i=1:height(T)
    p=char(T.(field)(i));if ~isempty(base),p=fullfile(base,p);end
    assert(strcmp(prc_file_hash(p),T.sha256(i)),'prb:ChangedInput','Changed input: %s',p);
end
end
function release(lock,channel,file),try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end,end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end
