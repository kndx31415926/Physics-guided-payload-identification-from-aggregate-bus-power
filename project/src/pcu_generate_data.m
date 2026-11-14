function info=pcu_generate_data(run_dir,cfg,spec)
%PRA_GENERATE_DATA Resume-safe, independent full-servo gradual-drift data.
% Final records are immutable, including failures. Generation may run in
% parallel because the within-episode physical state is reset; stream order
% defines drift/calibration causality, not a continuous physical simulation.
started=tic;run_dir=char(run_dir);if ~isfolder(run_dir),mkdir(run_dir);end
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'data_stage.lock'),'rw');channel=lockfile.getChannel();
try,stage_lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(stage_lock),channel.close();lockfile.close();error('pra:DataBusy','Another process owns this data stage.');end
lock_cleanup=onCleanup(@()release_lock(stage_lock,channel,lockfile)); %#ok<NASGU>
trial_dir=fullfile(run_dir,'trials');if ~isfolder(trial_dir),mkdir(trial_dir);end
candidate=pcu_data_plan(cfg,spec);spec=candidate.spec;plan_file=fullfile(run_dir,'data_plan.mat');resumed=isfile(plan_file);
if resumed
    plan=load(plan_file);
    fields={'schema','cfg_key','data_spec','objects','manifest','theta','known_theta','drifts','probe', ...
        'config_signature','source_signature','source_files','plan_signature'};
    assert(all(isfield(plan,fields)),'pra:PlanSchema','Existing data plan is incomplete.');
    for k=1:numel(fields)
        name=fields{k};assert(isequaln(plan.(name),candidate.(name)),'pra:PlanMismatch', ...
            'Fixed data plan field %s changed; preserve this run and use a new directory.',name);
    end
else
    assert(isempty(dir(fullfile(trial_dir,'trial_*.mat')))&&~isfile(fullfile(run_dir,'objects.csv'))&& ...
        ~isfile(fullfile(run_dir,'manifest.csv')),'pra:OrphanData','Found records without a fixed plan.');
    plan=candidate;temporary=temp_mat(run_dir);save(temporary,'-struct','plan','-v7.3');
    assert(~isfile(plan_file),'pra:PlanRace','Data plan appeared before commit.');
    [ok,message]=movefile(temporary,plan_file);assert(ok,'pra:PlanSave','%s',message);
end
clear candidate
write_or_check_tables(run_dir,plan.objects,plan.manifest);
N=height(plan.manifest);done=false(N,1);failed=false(N,1);physical_failed=false(N,1);unusable=false(N,1);exceptions=false(N,1);
expected=repmat(struct(),N,1);
for i=1:N
    row=plan.manifest(i,:);expected(i).schema=plan.schema;expected(i).run_id=spec.run_id;
    expected(i).plan_signature=plan.plan_signature;expected(i).config_signature=plan.config_signature;
    expected(i).source_signature=plan.source_signature;expected(i).trial_id=row.trial_id;
    expected(i).object_id=row.object_id;expected(i).split=char(row.split);expected(i).probe_id=plan.probe.id;
    expected(i).probe_index=spec.probe_index;expected(i).theta_true=plan.theta(i,:);expected(i).sensor_seed=row.sensor_seed;
    expected(i).scenario=char(row.scenario);expected(i).stream_seed=row.stream_seed;expected(i).stream_index=row.stream_index;
    expected(i).block=row.block;expected(i).role=char(row.role);expected(i).role_index=row.role_index;
    expected(i).chronological_index=row.chronological_index;expected(i).progress=row.progress;
    expected(i).paired_object_id=row.paired_object_id;expected(i).drift=plan.drifts(i);
    if row.role=="eval",expected(i).known_theta=[];else,expected(i).known_theta=plan.known_theta(i,:);end
    file=fullfile(trial_dir,sprintf('trial_%06d.mat',row.trial_id));
    if isfile(file)
        status=pgar_data_inspect_record(file,expected(i));done(i)=true;failed(i)=status.failed;
        physical_failed(i)=status.physical_failed;unusable(i)=status.unusable;exceptions(i)=status.exception;
    end
end
initial_done=sum(done);pending=find(~done);pool=[];own_pool=false;write_progress('running');
fprintf('PRA data %s: %d/%d complete; %d pending.\n',spec.run_id,initial_done,N,numel(pending));
try
    if ~isempty(pending)
        workers=spec.workers;pool=gcp('nocreate');
        if isempty(pool)
            cluster=parcluster('Processes');assert(workers<=cluster.NumWorkers,'pra:Workers','Worker limit exceeded.');
            pool=parpool(cluster,workers);own_pool=true;
        else
            assert(isa(pool,'parallel.ProcessPool')&&pool.NumWorkers==workers,'pra:ExistingPool','Existing pool must have %d processes.',workers);
        end
        pool_cleanup=onCleanup(@()close_owned_pool(pool,own_pool)); %#ok<NASGU>
        worker_path=path;
        spmd,path(worker_path);maxNumCompThreads(1);end %#ok<MAXNCT>
        queue=parallel.pool.DataQueue;afterEach(queue,@record_completed);
        heartbeat=timer('ExecutionMode','fixedSpacing','Period',30,'StartDelay',30,'BusyMode','drop', ...
            'TimerFcn',@(~,~)write_progress('running'));
        heartbeat_cleanup=onCleanup(@()close_timer(heartbeat));start(heartbeat); %#ok<NASGU>
        for first=1:workers:numel(pending)
            ids=pending(first:min(first+workers-1,numel(pending)));status_cells=cell(numel(ids),1);
            parfor j=1:numel(ids)
                id=ids(j);file=fullfile(trial_dir,sprintf('trial_%06d.mat',id));
                status_cells{j}=pra_data_trial(file,cfg,plan.probe,plan.drifts(id),expected(id));
                send(queue,struct('id',id,'status',status_cells{j}));
            end
            for j=1:numel(ids),record_completed(struct('id',ids(j),'status',status_cells{j}));end
            fprintf('PRA data saved %d/%d; failed=%d; elapsed %.1fs.\n',sum(done),N,sum(failed),toc(started));
        end
        clear heartbeat_cleanup
        clear pool_cleanup
    end
    assert(all(done),'pra:Incomplete','Not all planned records were saved.');
    info=progress('complete');info.skipped_existing=initial_done;info.generated_this_call=N-initial_done;
    info.resumed=resumed;info.elapsed_s=toc(started);info.plan_file=plan_file;
    atomic_json(fullfile(run_dir,'DATA_COMPLETE.json'),info);write_progress('complete');
    fprintf('PRA DATA COMPLETE: total=%d failed=%d generated=%d skipped=%d.\n',N,sum(failed),N-initial_done,initial_done);
catch err
    write_progress('interrupted');rethrow(err)
end
    function record_completed(event)
        i=event.id;v=event.status;done(i)=true;failed(i)=v.failed;physical_failed(i)=v.physical_failed;
        unusable(i)=v.unusable;exceptions(i)=v.exception;write_progress('running');
    end
    function p=progress(state)
        p=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
            'stage','data','state',state,'total',N,'done',sum(done),'failed',sum(failed), ...
            'physical_failed',sum(physical_failed),'unusable',sum(unusable),'exceptions',sum(exceptions), ...
            'timestamp',utc_now(),'elapsed_s',toc(started));
    end
    function write_progress(state),atomic_json(fullfile(run_dir,'progress_data.json'),progress(state));end
end
function write_or_check_tables(root,objects,manifest)
tables={objects,manifest};names={'objects.csv','manifest.csv'};
for k=1:2
    file=fullfile(root,names{k});expected=tables{k};
    if isfile(file)
        actual=readtable(file,'TextType','string');
        assert(isequal(actual.Properties.VariableNames,expected.Properties.VariableNames)&&height(actual)==height(expected), ...
            'pra:TableMismatch','Existing %s differs from plan.',names{k});
        for j=1:width(expected)
            a=actual.(j);b=expected.(j);
            if isnumeric(b),same=all(abs(a-b)<=1e-14,'all');else,same=isequal(string(a),string(b));end
            assert(same,'pra:TableMismatch','Existing %s differs from plan.',names{k});
        end
    else
        temporary=fullfile(root,['t_' char(javaMethod('randomUUID','java.util.UUID')) '.csv']);
        writetable(expected,temporary);[ok,message]=movefile(temporary,file);assert(ok,'pra:TableSave','%s',message);
    end
end
end
function name=temp_mat(folder),name=fullfile(folder,['t_' char(javaMethod('randomUUID','java.util.UUID')) '.mat']);end
function atomic_json(file,value)
temporary=fullfile(fileparts(file),['t_' char(javaMethod('randomUUID','java.util.UUID')) '.json']);
fid=fopen(temporary,'w','n','UTF-8');assert(fid>=0,'pra:ProgressWrite','Cannot write progress.');
cleanup=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));clear cleanup
[ok,message]=movefile(temporary,file,'f');assert(ok,'pra:ProgressWrite','%s',message);
end
function value=utc_now(),value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
function close_owned_pool(pool,owned),if owned,try,delete(pool);catch,end,end,end
function close_timer(t),try,stop(t);delete(t);catch,end,end
