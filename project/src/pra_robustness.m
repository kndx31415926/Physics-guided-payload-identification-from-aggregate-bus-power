function info=pra_robustness(run_dir,cfg,spec)
%PRA_ROBUSTNESS Frozen-model readout stress with object-level checkpoints.
% No parameter is selected or fitted here. Independent noise realizations
% repeat the same objects; summaries average errors, never their predictions.
required={'source_dir','lao_dir','robust_source_dir','robust_ids','robust_seeds'};
assert(all(isfield(spec,required)),'pra:Spec','Missing robustness specification.');
if ~isfield(spec,'robust_conditions'),spec.robust_conditions=pra_perturb_observation('conditions');end
C=spec.robust_conditions;ids=double(spec.robust_ids(:));seeds=double(spec.robust_seeds(:));
assert(~isempty(ids)&&all(ids>0&ids==floor(ids))&&numel(unique(ids))==numel(ids),'pra:IDs','Invalid object IDs.');
assert(~isempty(seeds)&&all(seeds>=0&seeds==floor(seeds))&&numel(unique(seeds))==numel(seeds),'pra:Seeds','Invalid noise seeds.');
assert(~isempty(C)&&numel(unique(string({C.id})))==numel(C),'pra:Conditions','Condition IDs must be unique.');
for j=1:numel(C)
    assert(~isempty(regexp(C(j).id,'^[a-zA-Z0-9_]+$','once')),'pra:ConditionName','Unsafe condition identifier.');
end
if ~isfolder(run_dir),mkdir(run_dir);end
directory=fullfile(run_dir,'robust_checkpoints');if ~isfolder(directory),mkdir(directory);end
started=tic;N=numel(ids);K=arrayfun(@(c)1+(numel(seeds)-1)*logical(c.randomized),C);
total=N*sum(K);done=0;reused=0;
status('preparing');
source_plan=load(fullfile(spec.robust_source_dir,'data_plan.mat'));
planrows=zeros(N,1);source_path=cell(N,1);source_hash=cell(N,1);
for i=1:N
    found=find(source_plan.objects.object_id==ids(i));
    assert(isscalar(found)&&string(source_plan.objects.split(found))=="test",'pra:SourceSplit','Only source test objects are allowed.');
    planrows(i)=found;source_path{i}=fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',ids(i)));
    source_hash{i}=prc_file_hash(source_path{i});
end
input_path={fullfile(spec.source_dir,'training_results.mat');fullfile(spec.lao_dir,'models.mat'); ...
    fullfile(spec.robust_source_dir,'configuration.mat');fullfile(spec.robust_source_dir,'data_plan.mat')};
input_hash=cellfun(@prc_file_hash,input_path,'UniformOutput',false);
critical=struct('legacy',cfg.legacy,'sim',cfg.sim,'sensor',cfg.sensor,'ident',cfg.ident,'payload',cfg.payload);
plan=struct('schema','pra_robustness_plan_v1','conditions',C,'ids',ids,'seeds',seeds, ...
    'cfg',critical,'source_dir',spec.robust_source_dir,'source_path',{source_path},'source_hash',{source_hash}, ...
    'model_input_path',{input_path},'model_input_hash',{input_hash},'created_utc',utc());
key=rmfield(plan,'created_utc');plan.run_key=hash_text(jsonencode(key));
plan_file=fullfile(run_dir,'robust_plan.mat');
if isfile(plan_file)
    saved=load(plan_file,'plan');assert(strcmp(saved.plan.run_key,plan.run_key),'pra:ResumeMismatch','Robustness inputs/configuration changed.');
    plan=saved.plan;
else
    assert(isempty(dir(fullfile(directory,'*.mat'))),'pra:OrphanCheckpoints','Checkpoints exist without their plan.');
    pgar_model_atomic_save(plan_file,struct('plan',plan));
end
writetable(table(ids,source_path,source_hash,'VariableNames',{'object_id','path','sha256'}),fullfile(run_dir,'robust_input_manifest.csv'));
predictor=pra_frozen_predict('load',cfg,spec);tables=cell(total,1);condition_index=zeros(total,1);z=0;
status('evaluating');
try
    for i=1:N
        loaded=load(source_path{i},'record');r=loaded.record;
        row=source_plan.objects(planrows(i),:);truth=[row.mass_kg row.cx_m row.cz_m];
        assert(r.object_id==ids(i)&&r.trial_id==ids(i)&&strcmp(string(r.split),"test")&& ...
            strcmp(r.plan_signature,source_plan.plan_signature)&&strcmp(r.run_id,source_plan.spec.run_id)&& ...
            all(abs(double(r.theta_true(:).')-truth)<=1e-12), ...
            'pra:SourceIdentity','Source record and fixed data plan disagree.');
        physical=false;
        if isstruct(r.truth)&&isfield(r.truth,'physical_success'),physical=logical(r.truth.physical_success);end
        for j=1:numel(C)
            if C(j).randomized,condition_seeds=seeds;else,condition_seeds=0;end
            for k=1:numel(condition_seeds)
                z=z+1;condition_index(z)=j;seed=condition_seeds(k);
                % Mix only public object index/condition/seed, never labels.
                realized_seed=mod(seed+1009*ids(i)+1000003*j,2^32);
                file=fullfile(directory,sprintf('o%06d_c%02d_r%02d.mat',ids(i),j,k));
                if isfile(file)
                    saved=load(file,'checkpoint');cp=saved.checkpoint;
                    assert(strcmp(cp.run_key,plan.run_key)&&strcmp(cp.source_hash,source_hash{i})&& ...
                        cp.object_id==ids(i)&&strcmp(cp.condition_id,C(j).id)&&cp.perturbation_seed==seed, ...
                        'pra:CheckpointMismatch','Existing robustness checkpoint differs.');
                    reused=reused+1;
                else
                    if isempty(r.obs)||~isempty(r.error)
                        prediction=pra_frozen_predict(predictor,struct());
                        meta=struct('scope','Source observation unavailable; planned failure retained.');
                    else
                        [observed,meta]=pra_perturb_observation(r.obs,cfg,C(j),realized_seed);
                        prediction=pra_frozen_predict(predictor,observed);
                    end
                    cp=struct('schema','pra_robust_checkpoint_v1','run_key',plan.run_key, ...
                        'object_id',ids(i),'condition_id',C(j).id,'perturbation_seed',seed, ...
                        'realized_seed',realized_seed,'source_hash',source_hash{i}, ...
                        'theta_true',truth,'physical_success',physical,'prediction',prediction, ...
                        'perturbation',meta,'completed_utc',utc());
                    pgar_model_atomic_save(file,struct('checkpoint',cp));
                end
                tables{z}=prediction_rows(cp);done=done+1;
                if mod(done,25)==0||done==total,status('evaluating');end
            end
        end
        fprintf('PRA robustness objects %d/%d, cases %d/%d, reused %d; %.1fs.\n',i,N,done,total,reused,toc(started));
    end
    assert(done==total);P=vertcat(tables{:});status('summarizing');
    S=summarize(P,N);writetable(P,fullfile(run_dir,'robust_predictions.csv'));
    writetable(S,fullfile(run_dir,'robust_summary.csv'));
    info=struct('schema','pra_robustness_complete_v1','run_key',plan.run_key,'planned_objects',N, ...
        'condition_count',numel(C),'planned_object_condition_replicates',total, ...
        'prediction_rows',height(P),'summary_rows',height(S),'reused_checkpoints',reused, ...
        'elapsed_s',toc(started),'prediction_path',fullfile(run_dir,'robust_predictions.csv'), ...
        'summary_path',fullfile(run_dir,'robust_summary.csv'),'completed_utc',utc(), ...
        'scope','Readout sensitivity on repeated held-out objects; frozen models; no tuning or mechanics change.');
    write_report(run_dir,plan,info);
    pgar_model_atomic_save(fullfile(run_dir,'robust_results.mat'),struct('info',info,'plan',plan,'summary',S));
    prc_write_json(fullfile(run_dir,'ROBUST_COMPLETE.json'),info);status('complete');
catch err
    status('failed',err.message);rethrow(err)
end
    function status(phase,message)
        if nargin<2,message='';end
        prc_write_json(fullfile(run_dir,'progress_robustness.json'),struct('phase',phase, ...
            'done',done,'total',total,'reused',reused,'elapsed_s',toc(started),'utc',utc(),'message',message));
    end
end

function T=prediction_rows(cp)
methods=cp.prediction.methods;rows=struct([]);
for m=1:numel(methods)
    M=methods(m);ns=numel(M.seeds);
    for s=1:ns+(ns>1)
        if s<=ns
            seed=M.seeds(s);kind='single';if ns==1,kind='deterministic';end
            raw=M.theta_raw(s,:);bounded=M.theta_clipped(s,:);valid=M.valid(s);hit=M.bound_hit(s);
        else
            seed=0;kind='ensemble';raw=M.ensemble_raw;bounded=M.ensemble_clipped;valid=M.ensemble_valid;hit=M.ensemble_bound_hit;
        end
        positive=all(isfinite(raw))&&raw(1)>0;
        for post=1:2
            if post==1,p=raw;processing='raw';else,p=bounded;processing='common_clip';end
            finite=all(isfinite(p));accepted=finite&&valid&&positive&&cp.physical_success;
            r=struct('condition',cp.condition_id,'perturbation_seed',cp.perturbation_seed, ...
                'realized_seed',cp.realized_seed,'object_id',cp.object_id,'method',M.name, ...
                'model_seed',seed,'model_kind',kind,'postprocessing',processing, ...
                'true_mass_kg',cp.theta_true(1),'true_cx_m',cp.theta_true(2),'true_cz_m',cp.theta_true(3), ...
                'pred_mass_kg',p(1),'pred_cx_m',p(2),'pred_cz_m',p(3), ...
                'finite_prediction',finite,'model_valid',logical(valid),'accepted',accepted, ...
                'raw_positive_mass',positive,'bounds_hit',logical(hit),'physical_success',cp.physical_success, ...
                'teacher_accepted',cp.prediction.features.teacher_accepted);
            if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        end
    end
end
T=struct2table(rows);
end

function S=summarize(P,N)
keys={'condition','perturbation_seed','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(P(:,keys));rows=struct([]);
for k=1:height(K)
    Q=P(G==k,:);assert(height(Q)==N&&numel(unique(Q.object_id))==N,'pra:SummaryDenominator','A replicate must include every planned object once.');
    true=[Q.true_mass_kg Q.true_cx_m Q.true_cz_m];prediction=[Q.pred_mass_kg Q.pred_cx_m Q.pred_cz_m];
    e=abs(prediction-true)*1000;finite=logical(Q.finite_prediction);accepted=logical(Q.accepted);
    mae=nan(1,3);rmse=mae;p95=mae;maximum=mae;accepted_mae=mae;mape=NaN;distance=NaN;distance95=NaN;
    if any(finite)
        mae=mean(e(finite,:),1);rmse=sqrt(mean(e(finite,:).^2,1));p95=prctile(e(finite,:),95,1);maximum=max(e(finite,:),[],1);
        mape=100*mean(e(finite,1)./(true(finite,1)*1000));
        d=vecnorm((prediction(finite,2:3)-true(finite,2:3))*1000,2,2);distance=mean(d);distance95=prctile(d,95);
    end
    if any(accepted),accepted_mae=mean(e(accepted,:),1);end
    row=struct('condition',char(string(Q.condition(1))),'perturbation_seed',Q.perturbation_seed(1), ...
        'method',char(string(Q.method(1))),'model_seed',Q.model_seed(1),'model_kind',char(string(Q.model_kind(1))), ...
        'postprocessing',char(string(Q.postprocessing(1))),'aggregation','single_perturbation_replicate', ...
        'replicate_count',1,'planned_objects',N,'planned_prediction_count',N, ...
        'finite_n',sum(finite),'model_valid_n',sum(Q.model_valid),'accepted_n',sum(accepted), ...
        'raw_positive_mass_n',sum(Q.raw_positive_mass),'bounds_hit_n',sum(Q.bounds_hit), ...
        'physical_success_n',sum(Q.physical_success),'prediction_coverage',mean(finite), ...
        'accepted_coverage',mean(accepted),'bounds_hit_rate',mean(Q.bounds_hit), ...
        'mass_mae_g',mae(1),'cx_mae_mm',mae(2),'cz_mae_mm',mae(3), ...
        'mass_rmse_g',rmse(1),'cx_rmse_mm',rmse(2),'cz_rmse_mm',rmse(3), ...
        'mass_p95_g',p95(1),'cx_p95_mm',p95(2),'cz_p95_mm',p95(3), ...
        'mass_max_g',maximum(1),'cx_max_mm',maximum(2),'cz_max_mm',maximum(3), ...
        'mass_mape_percent',mape,'planar_com_mean_distance_mm',distance,'planar_com_p95_distance_mm',distance95, ...
        'accepted_mass_mae_g',accepted_mae(1),'accepted_cx_mae_mm',accepted_mae(2),'accepted_cz_mae_mm',accepted_mae(3));
    if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
end
S=struct2table(rows);keys={'condition','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(S(:,keys));aggregate=struct([]);
counts={'finite_n','model_valid_n','accepted_n','raw_positive_mass_n','bounds_hit_n','physical_success_n'};
metrics={'prediction_coverage','accepted_coverage','bounds_hit_rate', ...
    'mass_mae_g','cx_mae_mm','cz_mae_mm','mass_rmse_g','cx_rmse_mm','cz_rmse_mm', ...
    'mass_p95_g','cx_p95_mm','cz_p95_mm','mass_max_g','cx_max_mm','cz_max_mm', ...
    'mass_mape_percent','planar_com_mean_distance_mm','planar_com_p95_distance_mm', ...
    'accepted_mass_mae_g','accepted_cx_mae_mm','accepted_cz_mae_mm'};
for k=1:height(K)
    Q=S(G==k,:);if height(Q)==1,continue,end
    row=table2struct(Q(1,:));row.perturbation_seed=-1;row.aggregation='mean_metrics_over_perturbation_replicates';
    row.replicate_count=height(Q);row.planned_prediction_count=N*height(Q);
    for j=1:numel(counts),row.(counts{j})=sum(Q.(counts{j}));end
    for j=1:numel(metrics),row.(metrics{j})=mean(Q.(metrics{j}));end
    if isempty(aggregate),aggregate=row;else,aggregate(end+1)=row;end %#ok<AGROW>
end
if ~isempty(aggregate),S=[S;struct2table(aggregate)];end
end

function write_report(root,plan,info)
fid=fopen(fullfile(root,'ROBUST_README.txt'),'w','n','UTF-8');assert(fid>=0);cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'Frozen-model measurement robustness\nRun key: %s\n',plan.run_key);
fprintf(fid,'%d original independent test objects; %d conditions; %d object-condition-noise replicates.\n', ...
    info.planned_objects,info.condition_count,info.planned_object_condition_replicates);
fprintf(fid,'These repeated conditions reuse the same objects, not additional independent object samples. No training, tuning, model selection or test-label inputs occur.\n');
fprintf(fid,'Additional Gaussian power noise has sigma=sqrt(target_sigma^2-0.03^2), then measurement gain and offset are applied.\n');
fprintf(fid,'Encoder quantization coarsens existing measurements; it does not regenerate analog readout or alter controller feedback. Pitch offset is a readout offset with signs [+1,-1,+1].\n');
fprintf(fid,'All plateau means, power deviations and stationarity gates are recomputed after perturbation. Real trajectories, commands and time are unchanged.\n');
fprintf(fid,'Raw and common_clip retain the complete planned denominator. Raw excludes additional output clipping, but preserves constraints inside the physics inverse.\n');
fprintf(fid,'Single/ensemble model seeds are distinguished. Ensembles average trained model predictions only. Noise replicates are NEVER averaged into a quieter prediction.\n');
fprintf(fid,'Rows with perturbation_seed=-1 average the per-replicate error metrics equally, including RMSE and P95; their *_n counts sum repeated evaluations. planned_objects remains the number of unique objects.\n');
fprintf(fid,'Acceptance combines method validity, finite output, positive native mass and external physical success. Finite rejected candidates remain in candidate metrics.\n');
fprintf(fid,'Coverage for frozen PGAR signal models retains their original shared feature computability checks; it is not an independent sensor-fault-tolerant implementation.\n');
fprintf(fid,'This is measurement sensitivity, not a mechanical wear experiment or a hardware accuracy guarantee.\n');
end

function v=hash_text(s)
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');md.update(unicode2native(s,'UTF-8'));
v=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function s=utc()
s=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
end
