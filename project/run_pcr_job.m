function run_pcr_job(run_dir)
% Independent Task Scheduler entry, frozen inputs and resumable chronology.
root=fileparts(mfilename('fullpath'));assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'pcr:Snapshot','Frozen source required.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();
assert(~isempty(lock),'pcr:Busy','Another worker owns this run.');cl=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PCR already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;phase='verify';started=tic;
try
    publish('running','Verifying frozen comparator source, original inputs and observations.');
    verify(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');verify(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    T=readtable(fullfile(spec.data_source_dir,'record_manifest.csv'),'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'VariableNamingRule','preserve');
    assert(sum(startsWith(T.relative_path,"trials"))==1408,'pcr:Records','Expected all1408 frozen trajectories.');
    for i=1:height(T)
        f=fullfile(spec.data_source_dir,char(T.relative_path(i)));
        assert(strcmp(prc_file_hash(f),T.sha256(i)),'pcr:RecordHash','Observation changed: %s',f);
    end
    phase='tests';publish('running','Running comparator contract tests before replay.');
    results=pcr_test_weighted_ridge();save(fullfile(run_dir,'test_results.mat'),'results');
    phase='online';publish('running','Replaying unknown predictions before reference-triggered ridge updates.');
    info=pcr_run_online(run_dir,cfg,spec);
    phase='matched_analysis';publish('running','Computing prespecified NN-minus-ridge paired stream comparisons.');
    info.matched_analysis=pcr_compare_models(run_dir,spec);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),struct('run_id',spec.run_id,'completed_utc',utc(),'elapsed_this_invocation_s',toc(started),'results',info));
    phase='complete';publish('complete','Supplemental replay, raw/clipped scores, costs and paired-stream intervals saved.');
catch err
    failure=struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc());
    prc_write_json(fullfile(run_dir,['failure_' char(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmss_SSS')) '.json']),failure);
    prc_write_json(fullfile(run_dir,'FAILED.json'),failure);
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,message)
        prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state,'phase',phase,'updated_utc',utc(),'matlab_pid',feature('getpid'),'message',message));
    end
end
function reset_path(root)
restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'tests'),fullfile(root,'vendor','bdcl_v29'));
end
function verify(file,base,key)
T=readtable(file,'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'VariableNamingRule','preserve');
for i=1:height(T),p=char(T.(key)(i));if ~isempty(base),p=fullfile(base,p);end;assert(strcmp(prc_file_hash(p),T.sha256(i)),'pcr:Hash','Changed %s',p);end
end
function release(lock,channel,file),try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end,end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end
