function info=psv_generate_data(run_dir,cfg,spec)
% Immutable new full-servo generation. A failed committed record is retained.
started=tic;plan=load(fullfile(run_dir,'data_plan.mat'));N=height(plan.manifest);folder=fullfile(run_dir,'trials');if ~isfolder(folder),mkdir(folder);end
ledger=psv_raw_manifest('load',run_dir,plan);
done=false(N,1);failed=done;physical_failed=done;unusable=done;exceptions=done;expected=cell(N,1);
for i=1:N
    row=plan.manifest(i,:);o=plan.objects(row.object_index,:);
    communication=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',row.communication_seed);
    expected{i}=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature,'trial_id',row.trial_id, ...
        'object_id',row.object_id,'split','test','probe_id',plan.probe.id,'probe_index',spec.probe_index, ...
        'theta_true',[o.mass_kg o.cx_m o.cz_m],'sensor_seed',row.sensor_seed,'communication',communication, ...
        'condition',char(row.condition),'condition_index',row.condition_index);
    file=fullfile(folder,sprintf('trial_%06d.mat',i));if isfile(file),register(i,pgar_data_inspect_record(file,expected{i}));end
end
initial=sum(done);pending=find(~done);write_progress('running');
if ~isempty(pending)
    if spec.workers>1
        pool=gcp('nocreate');owned=false;
        if isempty(pool),pool=parpool(parcluster('Processes'),spec.workers);owned=true;else,assert(pool.NumWorkers==spec.workers,'psv:Pool','Wrong existing worker count.');end
        pc=onCleanup(@()close_pool(pool,owned));worker_path=path;spmd,path(worker_path);maxNumCompThreads(1);end %#ok<NASGU,MAXNCT>
    end
    queue=parallel.pool.DataQueue;afterEach(queue,@completed);
    heartbeat=timer('ExecutionMode','fixedSpacing','Period',30,'StartDelay',30,'BusyMode','drop','TimerFcn',@(~,~)write_progress('running'));
    hc=onCleanup(@()close_timer(heartbeat));start(heartbeat); %#ok<NASGU>
    for first=1:spec.workers:numel(pending)
        ids=pending(first:min(first+spec.workers-1,numel(pending)));states=cell(numel(ids),1);
        if spec.workers==1
            i=ids(1);states{1}=psv_data_trial(fullfile(folder,sprintf('trial_%06d.mat',i)),cfg,plan.probe,plan.conditions(plan.manifest.condition_index(i)),expected{i});
        else
            parfor j=1:numel(ids)
                i=ids(j);states{j}=psv_data_trial(fullfile(folder,sprintf('trial_%06d.mat',i)),cfg,plan.probe,plan.conditions(plan.manifest.condition_index(i)),expected{i});
                send(queue,struct('id',i,'status',states{j}));
            end
        end
        for j=1:numel(ids),register(ids(j),states{j});end
        write_progress('running');fprintf('PSV full-servo %d/%d, failed %d, %.1fs\n',sum(done),N,sum(failed),toc(started));
    end
    clear hc pc
end
assert(all(done),'psv:Incomplete','Missing generated records.');
verified=psv_raw_manifest('load',run_dir,plan);assert(height(verified)==N&&isequaln(verified,ledger),'psv:ManifestIncomplete','Raw ledger is incomplete or changed.');
info=progress('complete');info.reused_records=initial;prc_write_json(fullfile(run_dir,'DATA_COMPLETE.json'),info);write_progress('complete');
    function register(i,s)
        if ~done(i),ledger=psv_raw_manifest('append',run_dir,plan,ledger,i);end
        done(i)=true;failed(i)=s.failed;physical_failed(i)=s.physical_failed;unusable(i)=s.unusable;exceptions(i)=s.exception;
    end
    function completed(e),register(e.id,e.status);write_progress('running');end
    function p=progress(state)
        p=struct('run_id',spec.run_id,'state',state,'phase','data','total',N,'done',sum(done),'failed',sum(failed), ...
            'physical_failed',sum(physical_failed),'unusable',sum(unusable),'exceptions',sum(exceptions),'elapsed_s',toc(started), ...
            'updated_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
    end
    function write_progress(state),prc_write_json(fullfile(run_dir,'progress_data.json'),progress(state));end
end
function close_pool(p,owned),if owned,try,delete(p);catch,end,end,end
function close_timer(t),try,stop(t);delete(t);catch,end,end
