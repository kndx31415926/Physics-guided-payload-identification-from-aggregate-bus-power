function info=prt_generate_data(run_dir,cfg,spec)
%PRT_GENERATE_DATA Resume-safe new servo episodes; legacy baseline reused.
started=tic;run_dir=char(run_dir);if ~isfolder(run_dir),mkdir(run_dir);end
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'data_stage.lock'),'rw');channel=lockfile.getChannel();
try,stage_lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(stage_lock),channel.close();lockfile.close();error('prt:DataBusy','Another process owns this data stage.');end
lock_cleanup=onCleanup(@()release_lock(stage_lock,channel,lockfile)); %#ok<NASGU>
trial_dir=fullfile(run_dir,'trials');if ~isfolder(trial_dir),mkdir(trial_dir);end
candidate=prt_data_plan(cfg,spec);spec=candidate.spec;plan_file=fullfile(run_dir,'data_plan.mat');resumed=isfile(plan_file);
if resumed
    plan=load(plan_file);assert(strcmp(plan.plan_signature,candidate.plan_signature),'prt:PlanMismatch','Fixed inputs/source/configuration changed; use a new run directory.');
else
    assert(isempty(dir(fullfile(trial_dir,'trial_*.mat'))),'prt:OrphanData','Records exist without a fixed plan.');
    plan=candidate;pgar_model_atomic_save(plan_file,plan);
end
clear candidate
writetable(plan.objects,fullfile(run_dir,'objects.csv'));writetable(plan.manifest,fullfile(run_dir,'manifest.csv'));
N=height(plan.manifest);new_ids=find(~plan.manifest.reuse_source);done=false(N,1);failed=done;physical_failed=done;unusable=done;exceptions=done;
expected=cell(N,1);
for i=1:N
    row=plan.manifest(i,:);object=plan.objects(row.source_index,:);
    expected{i}=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
        'trial_id',row.trial_id,'object_id',row.object_id,'split','test','probe_id',plan.probe.id, ...
        'probe_index',spec.probe_index,'theta_true',[object.mass_kg object.cx_m object.cz_m], ...
        'sensor_seed',row.sensor_seed,'condition',char(row.condition),'jitter_seed',row.jitter_seed, ...
        'realized_seed',row.realized_seed,'communication',plan.communications(i),'source_sha256',char(object.source_sha256));
    if row.reuse_source
        state=pgar_data_inspect_record(object.source_path,struct());register(i,state);
    else
        file=fullfile(trial_dir,sprintf('trial_%06d.mat',i));
        if isfile(file),state=pgar_data_inspect_record(file,expected{i});register(i,state);end
    end
end
initial_done=sum(done(new_ids));pending=find(~done);write_progress('running');
fprintf('PRT data %s: %d/%d new episodes saved; %d legacy cases reused.\n',spec.run_id,initial_done,numel(new_ids),N-numel(new_ids));
try
    if ~isempty(pending)
        if spec.workers>1
            pool=gcp('nocreate');own_pool=false;
            if isempty(pool),cluster=parcluster('Processes');pool=parpool(cluster,spec.workers);own_pool=true;
            else,assert(isa(pool,'parallel.ProcessPool')&&pool.NumWorkers==spec.workers,'prt:Pool','Existing pool has wrong type/size.');end
            pool_cleanup=onCleanup(@()close_pool(pool,own_pool)); %#ok<NASGU>
            worker_path=path;spmd,path(worker_path);maxNumCompThreads(1);end %#ok<MAXNCT>
        end
        queue=parallel.pool.DataQueue;afterEach(queue,@record_completed);
        heartbeat=timer('ExecutionMode','fixedSpacing','Period',30,'StartDelay',30,'BusyMode','drop','TimerFcn',@(~,~)write_progress('running'));
        heartbeat_cleanup=onCleanup(@()close_timer(heartbeat));start(heartbeat); %#ok<NASGU>
        for first=1:spec.workers:numel(pending)
            ids=pending(first:min(first+spec.workers-1,numel(pending)));states=cell(numel(ids),1);
            if spec.workers==1
                id=ids(1);file=fullfile(trial_dir,sprintf('trial_%06d.mat',id));
                states{1}=prt_data_trial(file,cfg,plan.probe,plan.drift,expected{id});
            else
                parfor j=1:numel(ids)
                    id=ids(j);file=fullfile(trial_dir,sprintf('trial_%06d.mat',id));
                    states{j}=prt_data_trial(file,cfg,plan.probe,plan.drift,expected{id});
                    send(queue,struct('id',id,'state',states{j}));
                end
            end
            for j=1:numel(ids),record_completed(struct('id',ids(j),'state',states{j}));end
            fprintf('PRT new episodes %d/%d; failed %d; %.1fs.\n',sum(done(new_ids)),numel(new_ids),sum(failed(new_ids)),toc(started));
        end
        clear heartbeat_cleanup pool_cleanup
    end
    assert(all(done),'prt:Incomplete','Some planned cases are missing.');
    info=progress('complete');info.resumed=resumed;info.skipped_existing=initial_done;info.generated_this_call=numel(new_ids)-initial_done;
    prc_write_json(fullfile(run_dir,'DATA_COMPLETE.json'),info);write_progress('complete');
catch err
    write_progress('interrupted');rethrow(err)
end
    function register(i,v)
        done(i)=true;failed(i)=v.failed;physical_failed(i)=v.physical_failed;unusable(i)=v.unusable;exceptions(i)=v.exception;
    end
    function record_completed(event),register(event.id,event.state);write_progress('running');end
    function p=progress(state)
        p=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature,'stage','data','state',state, ...
            'total',numel(new_ids),'done',sum(done(new_ids)),'failed',sum(failed(new_ids)), ...
            'physical_failed',sum(physical_failed(new_ids)),'unusable',sum(unusable(new_ids)),'exceptions',sum(exceptions(new_ids)), ...
            'planned_evaluation_cases',N,'reused_baseline_cases',N-numel(new_ids),'all_cases_done',sum(done),'all_cases_failed',sum(failed), ...
            'timestamp',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z''')),'elapsed_s',toc(started));
    end
    function write_progress(state),prc_write_json(fullfile(run_dir,'progress_data.json'),progress(state));end
end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
function close_pool(pool,owned),if owned,try,delete(pool);catch,end,end,end
function close_timer(t),try,stop(t);delete(t);catch,end,end
