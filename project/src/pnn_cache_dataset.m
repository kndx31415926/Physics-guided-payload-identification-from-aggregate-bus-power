function D=pnn_cache_dataset(run_dir,cfg,spec,splitlist)
%PNN_CACHE_DATASET Immutable per-episode observable features and audit rows.
% A failed episode/feature extraction remains in D and in every denominator.
started=tic;splitlist=unique(string(splitlist(:).'),'stable');
assert(~isempty(splitlist)&&all(ismember(splitlist,["train","validation","test"])), ...
    'pnn:Splits','Invalid requested split.');
plan=pnn_load_plan(run_dir,cfg,spec);if any(splitlist=="test"),pnn_test_gate(run_dir,plan);end
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'pnn_feature_stage.lock'),'rw');channel=lockfile.getChannel();
try,lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(lock),channel.close();lockfile.close();error('pnn:FeatureBusy','Another process owns feature extraction.');end
lc=onCleanup(@()release_lock(lock,channel,lockfile)); %#ok<NASGU>
folder=fullfile(run_dir,'feature_cache');if ~isfolder(folder),mkdir(folder);end
ids=find(ismember(plan.manifest.split,splitlist));N=numel(ids);done=false(N,1);
source_signature=extractor_signature();expected=cell(N,1);keys=cell(N,1);
for j=1:N
    i=ids(j);rawfile=fullfile(run_dir,'trials',sprintf('trial_%06d.mat',i));
    [~,seal]=pnn_checkpoint('read',rawfile);expected{j}=pnn_expected_record(plan,i);
    keys{j}=struct('schema','pnn_feature_checkpoint_v1','plan_signature',plan.plan_signature, ...
        'trial_id',i,'record_sha256',seal.sha256,'extractor_signature',source_signature);
    file=fullfile(folder,sprintf('feature_%06d.mat',i));
    if pnn_checkpoint('exists',file)
        S=pnn_checkpoint('read',file);assert(isequaln(S.checkpoint.key,keys{j}), ...
            'pnn:FeatureIdentity','Cached feature identity changed.');done(j)=true;
    end
end
pending=find(~done);write_progress('running');workers=spec.workers;
if ~isempty(pending)
    assert(ismember(workers,1:6),'pnn:Workers','At most six feature workers allowed.');
    if workers>1
        pool=gcp('nocreate');owned=false;
        if isempty(pool),pool=parpool(parcluster('Processes'),workers);owned=true;
        else,assert(isa(pool,'parallel.ProcessPool')&&pool.NumWorkers==workers,'pnn:Pool','Wrong existing process pool.');end
        pc=onCleanup(@()close_pool(pool,owned));worker_path=path;spmd,path(worker_path);maxNumCompThreads(1);end %#ok<NASGU,MAXNCT>
    else,maxNumCompThreads(1); %#ok<MAXNCT>
    end
    for first=1:workers:numel(pending)
        js=pending(first:min(first+workers-1,numel(pending)));jobs=cell(numel(js),1);
        for k=1:numel(js)
            j=js(k);i=ids(j);jobs{k}=struct('rawfile',fullfile(run_dir,'trials',sprintf('trial_%06d.mat',i)), ...
                'file',fullfile(folder,sprintf('feature_%06d.mat',i)),'key',keys{j},'expected',expected{j});
        end
        if workers==1,one_feature(jobs{1},cfg,spec);
        else,parfor k=1:numel(jobs),one_feature(jobs{k},cfg,spec);end,end
        done(js)=true;write_progress('running');
        if mod(sum(done),max(100,workers))<workers||all(done),fprintf('PNN feature cache %d/%d, %.1fs.\n',sum(done),N,toc(started));end
    end
    clear pc
end
M=plan.manifest(ids,:);O=plan.objects(M.object_index,:);
D=struct('schema','pnn_dataset_v1','plan_signature',plan.plan_signature,'source_signature',source_signature, ...
    'X13',nan(N,13),'Xaug',nan(N,52),'base',nan(N,3),'physics8',nan(N,3), ...
    'theta',[O.mass_kg O.cx_m O.cz_m],'usable',false(N,1),'accepted',false(N,1), ...
    'physics8accepted',false(N,1),'physics8usable',false(N,1),'physical_success',false(N,1), ...
    'feature_usable',false(N,1),'object_id',M.object_id,'trial_id',M.trial_id,'split',string(M.split), ...
    'condition',string(M.condition),'record_sha256',strings(N,1),'feature_sha256',strings(N,1));
for j=1:N
    [S,seal]=pnn_checkpoint('read',fullfile(folder,sprintf('feature_%06d.mat',ids(j))));cp=S.checkpoint;
    assert(isequaln(cp.key,keys{j}),'pnn:FeatureIdentity','Feature checkpoint changed during assembly.');F=cp.features;
    D.X13(j,:)=F.X13;D.Xaug(j,:)=F.Xaug;D.base(j,:)=F.base;D.physics8(j,:)=F.physics8;
    D.physical_success(j)=cp.physical_success;D.feature_usable(j)=F.usable;
    D.usable(j)=F.usable&&cp.physical_success;D.accepted(j)=F.accepted&&cp.physical_success;
    D.physics8accepted(j)=F.physics8accepted&&cp.physical_success;
    D.physics8usable(j)=F.physics8usable&&cp.physical_success;
    D.record_sha256(j)=string(cp.key.record_sha256);D.feature_sha256(j)=string(seal.sha256);
end
D.feature_names=feature_names();D.failed_n=sum(~D.usable);D.planned_n=N;
write_progress('complete');
    function write_progress(state)
        p=struct('phase','features','state',state,'plan_signature',plan.plan_signature, ...
            'splits',{cellstr(splitlist)},'done',sum(done),'total',N,'elapsed_s',toc(started), ...
            'updated_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
        prc_write_json(fullfile(run_dir,'progress_features.json'),p);
    end
end
function one_feature(job,cfg,spec)
[S,seal]=pnn_checkpoint('read',job.rawfile);assert(strcmp(seal.sha256,job.key.record_sha256),'pnn:RawChanged','Raw identity changed.');
status=pgar_data_inspect_record(job.rawfile,job.expected);
F=pnn_features(cfg,S.record.obs,spec);
checkpoint=struct('key',job.key,'features',F,'physical_success',~status.physical_failed, ...
    'record_status',status,'complete',true);
pnn_checkpoint('write',job.file,struct('checkpoint',checkpoint));
end
function value=extractor_signature()
names={'pnn_features','pnn_physics8','pgar_model_features','bpil_teacher','bpil_predict_power','bpil_static_design','bpil_hefting_features'};
value=struct();for k=1:numel(names),value.(names{k})=prc_file_hash(which(names{k}));end;value=psv_hash(value);
end
function names=feature_names()
names=["base_mass_scaled","base_cx_scaled","base_cz_scaled",compose("residual_pose_%d",1:8),"teacher_fit_rmse","teacher_holdout_rmse"];
for k=1:8,for j=1:3,names(end+1)=string(sprintf('J_pose_%d_parameter_%d',k,j));end,end %#ok<AGROW>
names=[names compose("power_sd_pose_%d",1:8),compose("GN_parameter_%d",1:3),compose("log_singular_%d",1:3),"log_condition"];
end
function release_lock(l,c,f),try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end;end
function close_pool(p,owned),if owned,try,delete(p);catch,end,end,end
