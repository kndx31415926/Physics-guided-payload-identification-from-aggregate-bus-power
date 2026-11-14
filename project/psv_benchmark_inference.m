function info=psv_benchmark_inference(source_run,output_dir,options)
%PSV_BENCHMARK_INFERENCE Separate, post-study wall-time benchmark.
% Full in-memory observation -> estimate, including fresh NLS/feature work.
% Never reads ground-truth fields, never modifies the frozen source run.
if nargin<1,source_run='C:\new\results\psv_frozen_confirmation_20261030_v2';end
if nargin<2,output_dir='C:\new\results\psv_inference_benchmark_20261030_v1';end
if nargin<3,options=struct();end
driver=[mfilename('fullpath') '.m'];oldpath=path;path_cleanup=onCleanup(@()path(oldpath)); %#ok<NASGU>
spec=struct('schema','psv_inference_benchmark_v1','source_run',source_run,'output_dir',output_dir, ...
    'smoke_test',false,'object_count',30,'repetitions',3,'warmup_repetitions',2,'execution_seed',1170101, ...
    'other_run','C:\new\results\pcu_prospective_20261030_v1','cpu_idle_max_percent',20,'cpu_idle_samples',3);
fields=fieldnames(options);for k=1:numel(fields),assert(isfield(spec,fields{k}),'psvBench:Option','Unknown option %s.',fields{k});spec.(fields{k})=options.(fields{k});end
if ~spec.smoke_test
    assert(spec.object_count==30&&spec.repetitions==3&&spec.warmup_repetitions==2&&spec.execution_seed==1170101, ...
        'psvBench:Protocol','Formal benchmark fixes 30 objects, three repeats, two warmups and the execution seed.');
    complete_and_exited(source_run);complete_and_exited(spec.other_run);
else,assert(isfile(fullfile(source_run,'COMPLETE.json')),'psvBench:Smoke','Smoke input run must be complete.');end
assert(~isfolder(output_dir),'psvBench:Exists','Choose a new benchmark output directory.');
snapshot=fullfile(source_run,'source_snapshot');configure_snapshot(snapshot);maxNumCompThreads(1);
assert(startsWith(string(which('pgar_model_features')),string(snapshot), 'IgnoreCase',true)&& ...
    startsWith(string(which('psf_features')),string(snapshot),'IgnoreCase',true),'psvBench:Path','Inference must resolve to the frozen source snapshot.');
verify_manifest(fullfile(source_run,'source_manifest.csv'),snapshot,'relative_path');
verify_manifest(fullfile(source_run,'input_manifest.csv'),'','input_path');
C=load(fullfile(source_run,'configuration.mat'),'cfg');cfg=C.cfg;
timer=tic;S=load(fullfile(source_run,'frozen_models.mat'),'models');models=S.models;model_load_s=toc(timer);
budget=find(models.spec.train_sizes==600);assert(isscalar(budget)&&numel(models.spec.network_seeds)==3,'psvBench:Models','Expected 600-object models and three NN seeds.');
plan=load(fullfile(source_run,'data_plan.mat'),'manifest');T=plan.manifest;
T=sortrows(T(T.condition=="nominal",:),'object_id');assert(height(T)>=spec.object_count,'psvBench:Cases','Too few nominal objects.');T=T(1:spec.object_count,:);
raw=readtable(fullfile(source_run,'raw_record_manifest.csv'),'TextType','string','Delimiter',',');
observations=cell(height(T),1);record_path=strings(height(T),1);record_hash=record_path;
for k=1:height(T)
    j=find(raw.trial_id==T.trial_id(k));assert(isscalar(j),'psvBench:Identity','Missing raw-record identity.');
    record_path(k)=raw.record_path(j);record_hash(k)=string(prc_file_hash(record_path(k)));
    assert(record_hash(k)==raw.sha256(j),'psvBench:RawChanged','Raw observation record changed.');
    saved=load(record_path(k),'record');assert(saved.record.trial_id==T.trial_id(k)&&saved.record.object_id==T.object_id(k),'psvBench:Identity','Wrong recorded case.');
    observations{k}=saved.record.obs;clear saved
end
machine=machine_info();machine.model_load_s=model_load_s;machine.single_computational_thread=true;
if spec.smoke_test,machine.cpu_before_percent=NaN;
else
    samples=zeros(1,spec.cpu_idle_samples);
    for k=1:numel(samples),samples(k)=cpu_percent();if k<numel(samples),pause(1);end,end
    assert(all(isfinite(samples))&&mean(samples)<=spec.cpu_idle_max_percent,'psvBench:CpuBusy', ...
        'CPU is not idle (samples %s percent). Retry after other work finishes.',mat2str(samples));machine.cpu_before_percent=samples;
end
methods=["steady_qp_nn40","steady_qps_nn48","physics_inverse","physics_residual_nn","physics_residual_ridge13"];
% Equivalence validation is outside all reported timing, before warmup.
[reference,~]=psv_predict(models,cfg,observations{1});
for m=1:numel(methods)
    y=method_inference(methods(m),models,budget,cfg,observations{1});
    at=find([reference.budget]==600&string({reference.name})==methods(m));assert(isscalar(at));
    assert(equal_numeric(y.raw,reference(at).raw)&&equal_numeric(y.clipped,reference(at).clipped)&&isequal(y.valid,reference(at).valid), ...
        'psvBench:Equivalence','Benchmark wrapper differs from frozen %s inference.',methods(m));
end
for w=1:spec.warmup_repetitions,for m=1:numel(methods),method_inference(methods(m),models,budget,cfg,observations{1});end,end
rows=struct([]);z=0;
for o=1:height(T),for r=1:spec.repetitions,for m=1:numel(methods)
    z=z+1;a=struct('object_index',o,'object_id',T.object_id(o),'trial_id',T.trial_id(o),'repetition',r,'method_index',m,'method',methods(m));
    if isempty(rows),rows=a;else,rows(z)=a;end %#ok<AGROW>
end,end,end
stream=RandStream('mt19937ar','Seed',spec.execution_seed);order=randperm(stream,z);execution=struct2table(rows(order));execution.execution_index=(1:z).';
mkdir(output_dir);copyfile(driver,fullfile(output_dir,'psv_benchmark_inference.m'));
copyfile(fullfile(source_run,'source_manifest.csv'),fullfile(output_dir,'frozen_source_manifest.csv'));
inputs=table(T.object_id,T.trial_id,record_path,record_hash,'VariableNames',{'object_id','trial_id','record_path','sha256'});
writetable(inputs,fullfile(output_dir,'observation_inputs.csv'));writetable(execution,fullfile(output_dir,'execution_plan.csv'));
hashes=struct('driver_sha256',prc_file_hash(driver),'models_sha256',prc_file_hash(fullfile(source_run,'frozen_models.mat')), ...
    'frozen_source_manifest_sha256',prc_file_hash(fullfile(source_run,'source_manifest.csv')), ...
    'configuration_sha256',prc_file_hash(fullfile(source_run,'configuration.mat')),'source_plan_sha256',prc_file_hash(fullfile(source_run,'data_plan.mat')));
prc_write_json(fullfile(output_dir,'spec.json'),spec);prc_write_json(fullfile(output_dir,'hashes.json'),hashes);
timings=struct([]);started=tic;
for k=1:height(execution)
    task=execution(k,:);whole=tic;
    [y,t]=method_inference(task.method,models,budget,cfg,observations{task.object_index});
    total=toc(whole);raw_mean=mean(y.raw,1);bounded_mean=mean(y.clipped,1);
    row=struct('execution_index',k,'object_id',task.object_id,'trial_id',task.trial_id,'repetition',task.repetition, ...
        'method',task.method,'train_budget',600,'model_member_count',size(y.raw,1),'feature_ms',1000*t.feature_s, ...
        'predictor_ms',1000*t.predictor_s,'total_ms',1000*total,'internal_ms',1000*t.internal_s, ...
        'finite',all(isfinite(raw_mean)),'valid',y.valid,'raw_mass_kg',raw_mean(1),'raw_cx_m',raw_mean(2),'raw_cz_m',raw_mean(3), ...
        'clipped_mass_kg',bounded_mean(1),'clipped_cx_m',bounded_mean(2),'clipped_cz_m',bounded_mean(3));
    if isempty(timings),timings=row;else,timings(end+1)=row;end %#ok<AGROW>
end
R=struct2table(timings);machine.timed_sequence_elapsed_s=toc(started);machine.cpu_after_percent=cpu_percent();
writetable(R,fullfile(output_dir,'timings.csv'));summary=summarize_timings(R);writetable(summary,fullfile(output_dir,'summary.csv'));
[G,K]=findgroups(R(:,{'object_id','method'}));object_summary=K;
for name={'feature_ms','predictor_ms','total_ms'},object_summary.([name{1} '_median'])=splitapply(@median,R.(name{1}),G);end
writetable(object_summary,fullfile(output_dir,'object_medians.csv'));prc_write_json(fullfile(output_dir,'machine.json'),machine);
info=struct('schema',spec.schema,'source_run',source_run,'objects',height(T),'methods',numel(methods),'repetitions',spec.repetitions,'timing_rows',height(R), ...
    'smoke_test',spec.smoke_test,'warmup_calls',spec.warmup_repetitions*numel(methods),'full_physics_features_recomputed_per_call',true, ...
    'source_run_modified',false,'truth_used',false,'completed_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
write_report(output_dir,spec,summary);save(fullfile(output_dir,'benchmark.mat'),'info','spec','machine','hashes','R','summary','object_summary');
prc_write_json(fullfile(output_dir,'COMPLETE.json'),info);fprintf('PSV inference %s complete: %s\n',ternary(spec.smoke_test,'INTERFACE SMOKE','BENCHMARK'),output_dir);
end
function [y,t]=method_inference(method,models,b,cfg,obs)
% Only the measured observation crosses this method boundary. No cache.
whole=tic;part=tic;physical=startsWith(method,"physics_");
if physical,F=pgar_model_features(cfg,obs,models.spec.scale,models.spec.probe_id);usable=F.usable;valid=usable&&F.teacher_accepted;
else,F=psf_features(obs,models.spec.probe_id);usable=F.usable;valid=usable;end
feature_s=toc(part);part=tic;count=3;
if method=="physics_inverse"||method=="physics_residual_ridge13",count=1;end
raw=nan(count,3);
if usable
    switch method
        case "physics_inverse",raw=F.base;
        case "physics_residual_ridge13"
            learner=models.students{b,4,1};raw=psf_ridge('predict',learner.model,F.residual(:,learner.columns)).*models.spec.scale+F.base;
        otherwise
            for s=1:count
                if method=="physics_residual_nn",learner=models.reference{b,s};X=F.residual;offset=F.base;
                elseif method=="steady_qp_nn40",learner=models.students{b,2,s};X=F.x;offset=zeros(1,3);
                else,assert(method=="steady_qps_nn48");learner=models.students{b,1,s};X=F.x48;offset=zeros(1,3);end
                raw(s,:)=predict(learner.model,X(:,learner.columns)).*models.spec.scale+offset;
            end
    end
end
bounded=min(max(raw,cfg.ident.bounds(:,1).'),cfg.ident.bounds(:,2).');bounded(~isfinite(raw))=NaN;
y=struct('raw',raw,'clipped',bounded,'ensemble_raw',mean(raw,1),'ensemble_clipped',mean(bounded,1),'valid',logical(valid));
t=struct('feature_s',feature_s,'predictor_s',toc(part),'internal_s',toc(whole));
end
function S=summarize_timings(R)
methods=unique(R.method,'stable');rows=struct([]);
for m=1:numel(methods)
    Q=R(R.method==methods(m),:);r=struct('method',methods(m),'objects',numel(unique(Q.object_id)),'calls',height(Q),'finite_calls',sum(Q.finite),'valid_calls',sum(Q.valid));
    for name={'feature_ms','predictor_ms','total_ms'}
        v=Q.(name{1});r.([name{1} '_mean'])=mean(v);r.([name{1} '_median'])=median(v);r.([name{1} '_p95'])=prctile(v,95);r.([name{1} '_max'])=max(v);
    end
    if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
end
S=struct2table(rows);
end
function complete_and_exited(folder)
assert(isfile(fullfile(folder,'COMPLETE.json')),'psvBench:RunningStudy','Wait for completed study: %s',folder);
file=fullfile(folder,'process_status.json');assert(isfile(file),'psvBench:Process','Missing independent-worker process status.');
P=jsondecode(fileread(file));assert(strcmp(P.state,'completed')&&P.matlab_exit_code==0,'psvBench:RunningStudy','Study worker has not exited cleanly: %s',folder);
end
function configure_snapshot(root),restoredefaultpath;addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));end
function verify_manifest(file,base,field)
T=readtable(file,'TextType','string','Delimiter',',','VariableNamingRule','preserve');
for k=1:height(T),p=char(T.(field)(k));if ~isempty(base),p=fullfile(base,p);end
    assert(strcmp(prc_file_hash(p),T.sha256(k)),'psvBench:ChangedSource','Changed frozen input: %s',p);
end
end
function M=machine_info()
M=struct('matlab_version',version,'matlab_release',version('-release'),'architecture',computer, ...
    'computer_name',getenv('COMPUTERNAME'),'processor_identifier',getenv('PROCESSOR_IDENTIFIER'), ...
    'logical_processors_environment',str2double(getenv('NUMBER_OF_PROCESSORS')),'toolboxes',{ver}, ...
    'recorded_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
if ispc
    [status,out]=system('powershell.exe -NoProfile -Command "Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors | ConvertTo-Json -Compress"');
    if status==0,try,M.processor=jsondecode(strtrim(out));catch,M.processor_query_output=strtrim(out);end,end
    [~,system_memory]=memory;M.memory=system_memory;
end
end
function value=cpu_percent()
value=NaN;if ~ispc,return,end
[status,out]=system('powershell.exe -NoProfile -Command "Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object Name -eq ''_Total'' | Select-Object -ExpandProperty PercentProcessorTime"');
if status==0,value=str2double(strtrim(out));end
end
function ok=equal_numeric(a,b)
ok=isequal(size(a),size(b))&&isequal(isnan(a),isnan(b));if ~ok,return,end
sel=isfinite(a)&isfinite(b);ok=all(abs(a(sel)-b(sel))<=1e-12)&&isequal(isinf(a),isinf(b));
end
function write_report(folder,spec,S)
fid=fopen(fullfile(folder,'BENCHMARK_CN.txt'),'w','n','UTF-8');assert(fid>=0);cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'独立推理计时；源运行：%s\n',spec.source_run);
if spec.smoke_test,fprintf(fid,'仅工程接口SMOKE：大任务仍可能运行，此处计时不得作为论文正式推理结果。\n');end
fprintf(fid,['600训练预算，前%d个名义对象，每方法每对象%d次；NN每次包括原三seed整体预测与集成。\n' ...
    '预热后按固定种子随机顺序执行；逐次重新从内存观测提取特征，物理方法逐次执行原NLS和完整pgar物理特征流程，没有复用特征/预测缓存。\n' ...
    '观测入口是原PSV observation结构，包含采集器已形成的八个稳态窗口摘要；窗口形成属于动作采集阶段，不计入这里的处理时间。\n' ...
    'total包括特征/NLS、所需预测器及结果组装；feature与predictor单独计时。物理逆解也沿用当前通用物理特征流程，含少量不被逆解单独使用的辅助特征计算。\n' ...
    '不含约22.6秒试探动作/数据采集、通信、模型加载和磁盘读取；不得把predictor部分当成物理方法全程推理。\n' ...
    '本机MATLAB墙钟描述统计，不是硬件实时性证明，也不是50ms控制周期内完成的保证。重复调用不能当作独立对象实验。\n\n'],spec.object_count,spec.repetitions);
for k=1:height(S),fprintf(fid,'%s: total median %.6g ms, P95 %.6g ms, max %.6g ms；feature median %.6g ms；predictor median %.6g ms。\n', ...
        S.method(k),S.total_ms_median(k),S.total_ms_p95(k),S.total_ms_max(k),S.feature_ms_median(k),S.predictor_ms_median(k));end
fprintf(fid,'\n逐次计时/执行顺序/对象原始记录哈希/源码与模型哈希/机器信息均单独保存。\n');
end
function s=ternary(flag,a,b),if flag,s=a;else,s=b;end,end
