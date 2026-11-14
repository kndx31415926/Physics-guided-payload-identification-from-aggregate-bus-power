function run_psv_job(run_dir)
% Immutable snapshot scheduled worker; no training or parameter selection.
root=fileparts(mfilename('fullpath'));assert(strcmpi(root,fullfile(run_dir,'source_snapshot')),'psv:Snapshot','Run snapshot entry.');
reset_path(root);maxNumCompThreads(1);
file=java.io.RandomAccessFile(fullfile(run_dir,'job.lock'),'rw');channel=file.getChannel();lock=channel.tryLock();assert(~isempty(lock),'psv:Busy','Worker already running.');
cleanup=onCleanup(@()release(lock,channel,file)); %#ok<NASGU>
if isfile(fullfile(run_dir,'COMPLETE.json')),fprintf('PSV already complete.\n');return,end
diary(fullfile(run_dir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
C=load(fullfile(run_dir,'configuration.mat'));cfg=C.cfg;spec=C.spec;phase='verification';started=tic;
try
    publish('running','Verifying frozen source, models, protocol and new object plan.');
    verify(fullfile(run_dir,'source_manifest.csv'),root,'relative_path');verify(fullfile(run_dir,'input_manifest.csv'),'','input_path');
    L=load(fullfile(run_dir,'LOCKED_BEFORE_GENERATION.mat'),'lock');assert(strcmp(L.lock.models_sha256,prc_file_hash(fullfile(run_dir,'frozen_models.mat')))&&~L.lock.model_selection_uses_new_tests,'psv:Lock','Invalid frozen-model lock.');
    phase='data';publish('running','Generating prespecified new full-servo objects and model-mismatch conditions.');data=psv_generate_data(run_dir,cfg,spec);
    phase='evaluation';publish('running','Observation-only frozen inference, paired scoring and bootstrap.');info=psv_evaluate(run_dir,cfg,spec);
    prc_write_json(fullfile(run_dir,'COMPLETE.json'),struct('run_id',spec.run_id,'completed_utc',utc(),'elapsed_this_invocation_s',toc(started),'smoke_test',spec.smoke_test,'data',data,'results',info));
    phase='complete';publish('complete','All prespecified frozen-model results saved.');
catch err
    prc_write_json(fullfile(run_dir,'FAILED.json'),struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'utc',utc()));
    publish('failed',err.message);fprintf(2,'%s\n',getReport(err,'extended','hyperlinks','off'));rethrow(err)
end
    function publish(state,message),prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',spec.run_id,'state',state,'phase',phase,'updated_utc',utc(),'smoke_test',spec.smoke_test,'message',message));end
end
function reset_path(root),restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));end
function verify(file,base,field)
T=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');for k=1:height(T)
    p=char(T.(field)(k));if ~isempty(base),p=fullfile(base,p);end
    assert(strcmp(prc_file_hash(p),T.sha256(k)),'psv:ChangedInput','Changed input: %s',p);
end
end
function release(lock,channel,file),try,lock.release();catch,end;try,channel.close();catch,end;try,file.close();catch,end,end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end
