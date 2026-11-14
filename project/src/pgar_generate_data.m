function info=pgar_generate_data(run_dir,cfg,spec)
%PGAR_GENERATE_DATA Resumable, fixed-robot full-servo object data generation.
% The caller controls MATLAB paths, including any immutable source snapshot.
% One LHS object is one full eight-posture episode; split seeds are independent.
% Completed records, including simulation failures, are never regenerated.
% Only progress_data.json is updated here; the caller owns root status.json.
started=tic;spec=validate_spec(spec);run_dir=char(run_dir);
assert(isfolder(fileparts(run_dir))||isfolder(run_dir),'pgar:RunParent','Run parent directory must exist.');
if ~isfolder(run_dir),mkdir(run_dir);end
% An OS file lock is released by the OS after an interrupted MATLAB process.
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'data_stage.lock'),'rw');
channel=lockfile.getChannel();
try,stage_lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(stage_lock),channel.close();lockfile.close();error('pgar:DataBusy','Another process owns this data stage.');end
lock_cleanup=onCleanup(@()release_lock(stage_lock,channel,lockfile)); %#ok<NASGU>
trial_dir=fullfile(run_dir,'trials');if ~isfolder(trial_dir),mkdir(trial_dir);end
probes=bpil_probe_library(cfg);
assert(spec.probe_index<=numel(probes),'pgar:Probe','Invalid probe index.');
probe=probes(spec.probe_index);drift=bpil_drift(1,1,'common');
cfg_key=critical_config(cfg);data_spec=dataset_spec(spec);
schema='pgar_full_servo_data_v1';plan_file=fullfile(run_dir,'data_plan.mat');
resumed=isfile(plan_file);
if resumed
    plan=load(plan_file);
    assert(all(isfield(plan,{'schema','cfg','spec','cfg_key','data_spec','objects','manifest','probe','drift','plan_signature'})), ...
        'pgar:PlanSchema','Existing data plan is incomplete.');
    assert(strcmp(plan.schema,schema)&&isequaln(plan.data_spec,data_spec), ...
        'pgar:PlanMismatch','Run ID, counts, split/sensor seeds, probe or object range changed.');
    assert(isequaln(plan.cfg_key,cfg_key)&&isequaln(plan.probe,probe)&&isequaln(plan.drift,drift), ...
        'pgar:ConfigMismatch','A data-generating configuration or probe changed; use a new run directory.');
else
    assert(isempty(dir(fullfile(trial_dir,'trial_*.mat')))&& ...
        ~isfile(fullfile(run_dir,'objects.csv'))&&~isfile(fullfile(run_dir,'manifest.csv')), ...
        'pgar:OrphanData','Found data without data_plan.mat; preserve it and use a new run directory.');
    old_rng=rng;rng_cleanup=onCleanup(@()rng(old_rng)); %#ok<NASGU>
    names={'train','validation','test'};theta=[];split=strings(0,1);
    for k=1:3
        rng(spec.split_seeds(k),'twister');
        U=lhsdesign(spec.counts(k),3,'criterion','maximin','iterations',10);
        theta=[theta;spec.range_lower+U.*spec.range_span]; %#ok<AGROW>
        split=[split;repmat(string(names{k}),spec.counts(k),1)]; %#ok<AGROW>
    end
    assert(size(unique(theta,'rows'),1)==size(theta,1),'pgar:DuplicateObjects','Duplicate object parameters.');
    n=size(theta,1);ids=(1:n).';
    objects=table(ids,split,theta(:,1),theta(:,2),theta(:,3), ...
        'VariableNames',{'object_id','split','mass_kg','cx_m','cz_m'});
    manifest=table(ids,ids,repmat(spec.probe_index,n,1),split,spec.sensor_seed_base+ids, ...
        'VariableNames',{'trial_id','object_id','probe_index','split','sensor_seed'});
    plan_signature=signature(struct('schema',schema,'data_spec',data_spec,'cfg_key',cfg_key,'probe',probe,'drift',drift));
    plan=struct('schema',schema,'cfg',cfg,'spec',spec,'cfg_key',cfg_key,'data_spec',data_spec, ...
        'objects',objects,'manifest',manifest,'probe',probe,'drift',drift, ...
        'plan_signature',plan_signature,'created_utc',utc_now());
    temporary=[plan_file '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
    save(temporary,'-struct','plan','-v7.3');
    assert(~isfile(plan_file),'pgar:PlanRace','Data plan appeared while creating it.');
    [ok,message]=movefile(temporary,plan_file);assert(ok,'pgar:PlanSave','%s',message);
    clear rng_cleanup
end
write_or_check_tables(run_dir,plan.objects,plan.manifest);
N=height(plan.objects);done=false(N,1);failed=false(N,1);
physical_failed=false(N,1);unusable=false(N,1);exceptions=false(N,1);
expected=repmat(struct(),N,1);
for i=1:N
    expected(i).schema=schema;expected(i).run_id=spec.run_id;expected(i).plan_signature=plan.plan_signature;
    expected(i).trial_id=i;expected(i).object_id=plan.manifest.object_id(i);
    expected(i).split=char(plan.manifest.split(i));expected(i).probe_id=plan.probe.id;
    expected(i).probe_index=spec.probe_index;
    expected(i).theta_true=[plan.objects.mass_kg(i),plan.objects.cx_m(i),plan.objects.cz_m(i)];
    expected(i).sensor_seed=plan.manifest.sensor_seed(i);
    file=fullfile(trial_dir,sprintf('trial_%06d.mat',i));
    if isfile(file)
        status=pgar_data_inspect_record(file,expected(i));
        done(i)=true;failed(i)=status.failed;physical_failed(i)=status.physical_failed;
        unusable(i)=status.unusable;exceptions(i)=status.exception;
    end
end
initial_done=sum(done);pending=find(~done);pool=[];own_pool=false;
write_progress('running');
fprintf('PGAR data %s: %d/%d records already complete; %d pending.\n',spec.run_id,initial_done,N,numel(pending));
try
    if ~isempty(pending)
        workers=spec.workers;pool=gcp('nocreate');
        if isempty(pool)
            cluster=parcluster('Processes');
            assert(workers<=cluster.NumWorkers,'pgar:Workers','Requested workers exceed the Processes profile limit.');
            pool=parpool(cluster,workers);own_pool=true;
        else
            assert(isa(pool,'parallel.ProcessPool')&&pool.NumWorkers==workers, ...
                'pgar:ExistingPool','Existing pool must be a Processes pool with %d workers.',workers);
        end
        pool_cleanup=onCleanup(@()close_owned_pool(pool,own_pool)); %#ok<NASGU>
        worker_path=path;
        spmd
            path(worker_path);
            maxNumCompThreads(1); %#ok<MAXNCT>
        end
        queue=parallel.pool.DataQueue;afterEach(queue,@record_completed);
        heartbeat=timer('ExecutionMode','fixedSpacing','Period',30,'StartDelay',30, ...
            'BusyMode','drop','TimerFcn',@(~,~)write_progress('running'));
        heartbeat_cleanup=onCleanup(@()close_timer(heartbeat)); %#ok<NASGU>
        start(heartbeat);
        % One wave per batch makes cancellation/resumption boundaries explicit.
        for first=1:workers:numel(pending)
            ids=pending(first:min(first+workers-1,numel(pending)));status_cells=cell(numel(ids),1);
            parfor j=1:numel(ids)
                id=ids(j);file=fullfile(trial_dir,sprintf('trial_%06d.mat',id));
                status_cells{j}=pgar_data_trial(file,cfg,plan.probe,plan.drift,expected(id));
                send(queue,struct('id',id,'status',status_cells{j}));
            end
            for j=1:numel(ids),record_completed(struct('id',ids(j),'status',status_cells{j}));end
            fprintf('PGAR data saved %d/%d; failed=%d; elapsed %.1fs.\n',sum(done),N,sum(failed),toc(started));
        end
        clear heartbeat_cleanup
        clear pool_cleanup
    end
    assert(all(done),'pgar:Incomplete','Not all planned trial records were saved.');
    info=progress('complete');info.skipped_existing=initial_done;info.generated_this_call=N-initial_done;
    info.resumed=resumed;info.elapsed_s=toc(started);info.plan_file=plan_file;
    atomic_json(fullfile(run_dir,'DATA_COMPLETE.json'),info);
    write_progress('complete');
    fprintf('PGAR DATA COMPLETE: total=%d failed=%d generated=%d skipped=%d.\n',N,sum(failed),N-initial_done,initial_done);
catch err
    write_progress('interrupted');rethrow(err)
end
    function record_completed(event)
        i=event.id;v=event.status;done(i)=true;failed(i)=v.failed;
        physical_failed(i)=v.physical_failed;unusable(i)=v.unusable;exceptions(i)=v.exception;
        write_progress('running');
    end
    function p=progress(state)
        p=struct('schema',schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
            'stage','data','state',state,'total',N,'done',sum(done),'failed',sum(failed), ...
            'physical_failed',sum(physical_failed),'unusable',sum(unusable),'exceptions',sum(exceptions), ...
            'timestamp',utc_now(),'elapsed_s',toc(started));
    end
    function write_progress(state)
        atomic_json(fullfile(run_dir,'progress_data.json'),progress(state));
    end
end

function s=validate_spec(s)
required={'run_id','counts','split_seeds','sensor_seed_base','probe_index','workers','range_lower','range_span'};
assert(isstruct(s)&&isscalar(s)&&all(isfield(s,required)),'pgar:Spec','Missing required data specification.');
s.run_id=char(string(s.run_id));assert(~isempty(s.run_id)&&isrow(s.run_id),'pgar:RunID','Expected a nonempty scalar run ID.');
for field={'counts','split_seeds','range_lower','range_span'}
    name=field{1};s.(name)=double(s.(name)(:).');
    assert(numel(s.(name))==3&&isreal(s.(name))&&all(isfinite(s.(name))),'pgar:Spec','%s must contain three finite real values.',name);
end
assert(all(s.counts>=1)&all(s.counts==floor(s.counts)),'pgar:Counts','All three splits need positive integer sizes.');
assert(numel(unique(s.split_seeds))==3&&all(s.split_seeds>=0)&all(s.split_seeds==floor(s.split_seeds)), ...
    'pgar:Seeds','Three distinct nonnegative integer split seeds are required.');
for field={'sensor_seed_base','probe_index','workers'}
    v=s.(field{1});assert(isnumeric(v)&&isreal(v)&&isscalar(v)&&isfinite(v)&&v==floor(v),'pgar:Spec','Invalid %s.',field{1});
end
assert(s.sensor_seed_base>=0&&s.sensor_seed_base+sum(s.counts)<=2^32-1&&all(s.split_seeds<=2^32-1), ...
    'pgar:Seeds','RNG seeds are outside the supported range.');
assert(s.workers>=1&&s.probe_index>=1&&all(s.range_span>0)&&s.range_lower(1)>0,'pgar:Spec','Invalid worker, probe or object range.');
end
function s=dataset_spec(spec)
% Worker count changes execution resources, never the fixed dataset.
fields={'run_id','counts','split_seeds','sensor_seed_base','probe_index','range_lower','range_span'};
s=struct();for k=1:numel(fields),s.(fields{k})=spec.(fields{k});end
end
function key=critical_config(cfg)
fields={'legacy','payload','sensor','sim','ident'};key=struct();
for k=1:numel(fields),assert(isfield(cfg,fields{k}),'pgar:Config','Missing cfg.%s.',fields{k});key.(fields{k})=cfg.(fields{k});end
end
function value=signature(input)
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');
md.update(unicode2native(jsonencode(input),'UTF-8'));
value=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function write_or_check_tables(root,objects,manifest)
tables={objects,manifest};names={'objects.csv','manifest.csv'};
for k=1:2
    file=fullfile(root,names{k});expected=tables{k};
    if isfile(file)
        actual=readtable(file,'TextType','string');
        assert(isequal(actual.Properties.VariableNames,expected.Properties.VariableNames)&&height(actual)==height(expected), ...
            'pgar:TableMismatch','Existing %s differs from the fixed plan.',names{k});
        for j=1:width(expected)
            a=actual.(j);b=expected.(j);
            if isnumeric(b),same=all(abs(a-b)<=1e-14,'all');else,same=isequal(string(a),string(b));end
            assert(same,'pgar:TableMismatch','Existing %s differs from the fixed plan.',names{k});
        end
    else
        temporary=[file '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
        writetable(expected,temporary,'FileType','text');
        [ok,message]=movefile(temporary,file);assert(ok,'pgar:TableSave','%s',message);
    end
end
end
function atomic_json(file,value)
temporary=[file '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
fid=fopen(temporary,'w','n','UTF-8');assert(fid>=0,'pgar:ProgressWrite','Cannot write %s.',temporary);
cleanup=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));clear cleanup
[ok,message]=movefile(temporary,file,'f');assert(ok,'pgar:ProgressWrite','%s',message);
end
function value=utc_now()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
function close_owned_pool(pool,owned)
if owned,try,delete(pool);catch,end,end
end
function close_timer(t)
try,stop(t);delete(t);catch,end
end
