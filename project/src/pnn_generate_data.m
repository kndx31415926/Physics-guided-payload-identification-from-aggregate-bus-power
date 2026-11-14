function info=pnn_generate_data(run_dir,cfg,spec,splitlist)
%PNN_GENERATE_DATA Resumable six-process full-servo episodes, one thread each.
% The frozen test groups are generated only after a verified model lock.
started=tic;splitlist=unique(string(splitlist(:).'),'stable');
assert(~isempty(splitlist)&&all(ismember(splitlist,["train","validation","test"])), ...
    'pnn:Splits','Invalid requested split.');
plan=pnn_load_plan(run_dir,cfg,spec);if any(splitlist=="test"),pnn_test_gate(run_dir,plan);end
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'pnn_data_stage.lock'),'rw');channel=lockfile.getChannel();
try,lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(lock),channel.close();lockfile.close();error('pnn:DataBusy','Another process owns this data stage.');end
lc=onCleanup(@()release_lock(lock,channel,lockfile)); %#ok<NASGU>
folder=fullfile(run_dir,'trials');if ~isfolder(folder),mkdir(folder);end
M=plan.manifest;selected=find(ismember(M.split,splitlist));N=height(M);done=false(N,1);failed=done;physical_failed=done;unusable=done;exceptions=done;
for i=selected(:).'
    file=fullfile(folder,sprintf('trial_%06d.mat',i));
    if pnn_checkpoint('exists',file)
        pnn_checkpoint('read',file);register(i,pgar_data_inspect_record(file,pnn_expected_record(plan,i)));
    end
end
initial=sum(done);pending=selected(~done(selected));write_progress('running');
fprintf('PNN full-servo %s: %d/%d sealed, %d pending.\n',strjoin(splitlist,','),initial,numel(selected),numel(pending));
if ~isempty(pending)
    workers=spec.workers;assert(ismember(workers,[1 2 3 4 5 6]),'pnn:Workers','At most six workers allowed.');
    if workers>1
        pool=gcp('nocreate');owned=false;
        if isempty(pool),pool=parpool(parcluster('Processes'),workers);owned=true;
        else,assert(isa(pool,'parallel.ProcessPool')&&pool.NumWorkers==workers,'pnn:Pool','Wrong existing process pool.');end
        pc=onCleanup(@()close_pool(pool,owned));worker_path=path;spmd,path(worker_path);maxNumCompThreads(1);end %#ok<NASGU,MAXNCT>
    else,maxNumCompThreads(1); %#ok<MAXNCT>
    end
    queue=parallel.pool.DataQueue;afterEach(queue,@completed);
    timerobj=timer('ExecutionMode','fixedSpacing','Period',30,'StartDelay',30,'BusyMode','drop','TimerFcn',@(~,~)write_progress('running'));
    tc=onCleanup(@()close_timer(timerobj));start(timerobj); %#ok<NASGU>
    for first=1:workers:numel(pending)
        ids=pending(first:min(first+workers-1,numel(pending)));states=cell(numel(ids),1);expected=cell(numel(ids),1);
        for j=1:numel(ids),expected{j}=pnn_expected_record(plan,ids(j));end
        if workers==1
            i=ids(1);states{1}=pnn_trial(fullfile(folder,sprintf('trial_%06d.mat',i)),cfg,plan.probe,plan.conditions(i),expected{1});
        else
            parfor j=1:numel(ids)
                i=ids(j);states{j}=pnn_trial(fullfile(folder,sprintf('trial_%06d.mat',i)),cfg,plan.probe,plan.conditions(i),expected{j});
                send(queue,struct('id',i,'status',states{j}));
            end
        end
        for j=1:numel(ids),register(ids(j),states{j});end
        write_progress('running');fprintf('PNN sealed %d/%d, failed %d, %.1fs.\n',sum(done),numel(selected),sum(failed),toc(started));
    end
    clear tc pc
end
assert(all(done(selected)),'pnn:DataIncomplete','Some planned episodes were not saved.');
info=progress('complete');info.skipped_existing=initial;info.generated_this_call=numel(selected)-initial;
for name=splitlist
    marker=fullfile(run_dir,['DATA_' upper(char(name)) '_COMPLETE.json']);
    m=struct('schema',plan.schema,'run_id',char(string(spec.run_id)),'plan_signature',plan.plan_signature,'split',char(name), ...
        'total',sum(M.split==name),'failed',sum(failed(M.split==name)),'complete',true);
    if isfile(marker),assert(isequaln(jsondecode(fileread(marker)),m),'pnn:DataMarkerChanged','Completed split marker changed.');
    else,prc_write_json(marker,m);end
end
write_progress('complete');
    function register(i,s)
        done(i)=true;failed(i)=s.failed;physical_failed(i)=s.physical_failed;unusable(i)=s.unusable;exceptions(i)=s.exception;
    end
    function completed(e),register(e.id,e.status);write_progress('running');end
    function p=progress(state)
        p=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
            'phase','data','state',state,'splits',{cellstr(splitlist)},'total',numel(selected),'done',sum(done), ...
            'failed',sum(failed),'physical_failed',sum(physical_failed),'unusable',sum(unusable), ...
            'exceptions',sum(exceptions),'elapsed_s',toc(started), ...
            'updated_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
    end
    function write_progress(state),prc_write_json(fullfile(run_dir,'progress_data.json'),progress(state));end
end
function release_lock(l,c,f),try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end;end
function close_pool(p,owned),if owned,try,delete(p);catch,end,end,end
function close_timer(t),try,stop(t);delete(t);catch,end,end
