function info=psv_evaluate(run_dir,cfg,spec)
% Prediction boundary sees only obs; truths enter the outer scoring stage.
assert(isfile(fullfile(run_dir,'DATA_COMPLETE.json'))&&isfile(fullfile(run_dir,'LOCKED_BEFORE_GENERATION.mat')),'psv:Stage','Missing stage lock.');
S=load(fullfile(run_dir,'frozen_models.mat'),'models');models=S.models;literature=load(fullfile(run_dir,'frozen_lao_models.mat'),'model','pe');
plan=load(fullfile(run_dir,'data_plan.mat'));T=plan.manifest;N=height(T);tables=cell(N,1);failureRows=cell(N,1);reused=0;
raw=readtable(fullfile(run_dir,'raw_record_manifest.csv'),'TextType','string','Delimiter',',');
key=struct('model_hash',prc_file_hash(fullfile(run_dir,'frozen_models.mat')),'lao_hash',prc_file_hash(fullfile(run_dir,'frozen_lao_models.mat')), ...
    'plan_hash',prc_file_hash(fullfile(run_dir,'data_plan.mat')),'code_hash',prc_file_hash(mfilename('fullpath')+".m"));
folder=fullfile(run_dir,'evaluation_checkpoints');if ~isfolder(folder),mkdir(folder);end
for i=1:N
    row=T(i,:);file=fullfile(folder,sprintf('case_%06d.mat',i));record_hash=prc_file_hash(raw.record_path(i));
    assert(record_hash==raw.sha256(i),'psv:RawChanged','A generated record changed.');
    if isfile(file)
        C=load(file,'checkpoint');cp=C.checkpoint;assert(isequaln(cp.key,key)&&cp.trial_id==i&&strcmp(cp.record_hash,record_hash),'psv:Resume','Evaluation checkpoint mismatch.');reused=reused+1;
    else
        C=load(raw.record_path(i),'record');r=C.record;
        assert(r.trial_id==row.trial_id&&r.object_id==row.object_id&&strcmp(r.plan_signature,plan.plan_signature),'psv:Identity','Wrong case identity.');
        timer=tic;[M,F]=psv_predict(models,cfg,r.obs);M=[M psv_lao_predict(literature,cfg,r.obs)];inference=toc(timer);
        % Deliberately after all observation-only inference, including Lao.
        physical=isempty(r.error)&&isstruct(r.truth)&&isfield(r.truth,'physical_success')&&r.truth.physical_success;
        truth=r.theta_true;rows=prediction_rows(row,M,truth,F,physical);
        reasons="";if ~isempty(r.error),reasons=string(r.error.identifier)+": "+string(r.error.message);
        elseif ~isempty(r.truth.reasons),reasons=strjoin(string(r.truth.reasons),"; ");end
        failure=table(row.trial_id,row.object_id,row.condition,logical(physical),F.steady.usable,F.physics.usable,F.physics.teacher_accepted, ...
            ~isempty(r.error),reasons,string(strjoin(F.physics.reasons,'; ')),inference, ...
            'VariableNames',{'trial_id','object_id','condition','physical_success','steady_usable','physics_usable','teacher_accepted','exception','failure_reason','physics_reason','all_method_inference_s'});
        cp=struct('key',key,'trial_id',i,'record_hash',record_hash,'rows',rows,'failure',failure);pgar_model_atomic_save(file,struct('checkpoint',cp));
    end
    tables{i}=cp.rows;failureRows{i}=cp.failure;
    if mod(i,25)==0||i==N,prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('done',i,'total',N,'reused',reused));fprintf('PSV inference %d/%d\n',i,N);end
end
R=vertcat(tables{:});failures=vertcat(failureRows{:});summary=psv_summarize(R);
writetable(R,fullfile(run_dir,'predictions.csv'));writetable(summary,fullfile(run_dir,'summary.csv'));writetable(failures,fullfile(run_dir,'case_diagnostics.csv'));
bad=~failures.physical_success|~failures.steady_usable|~failures.physics_usable|failures.exception;
writetable(failures(bad,:),fullfile(run_dir,'failed_cases.csv'));
[paired,intervals]=psv_bootstrap(R,spec);writetable(paired,fullfile(run_dir,'paired_object_differences.csv'));writetable(intervals,fullfile(run_dir,'paired_bootstrap.csv'));
info=struct('planned_cases',N,'unique_objects',height(plan.objects),'condition_count',numel(plan.conditions),'prediction_rows',height(R), ...
    'failed_cases',sum(bad),'physical_failed',sum(~failures.physical_success),'exceptions',sum(failures.exception), ...
    'finite_row_count',sum(R.finite_prediction),'summary_rows',height(summary),'bootstrap_rows',height(intervals),'reused_checkpoints',reused, ...
    'smoke_test',spec.smoke_test,'models_retrained',false,'test_used_for_selection',false);
pgar_model_atomic_save(fullfile(run_dir,'results.mat'),struct('info',info,'summary',summary,'intervals',intervals));
psv_write_report(run_dir,spec,summary,intervals,info);
end
function T=prediction_rows(row,M,truth,F,physical)
rows=struct([]);
for m=1:numel(M)
    a=M(m);n=size(a.raw,1);
    for s=1:n+(n>1)
        seed=0;kind="deterministic";
        if s<=n
            raw=a.raw(s,:);bounded=a.clipped(s,:);seed=a.seeds(s);if seed~=0,kind="single";end
            valid=a.valid(min(s,numel(a.valid)));
        else,raw=mean(a.raw,1);bounded=mean(a.clipped,1);kind="ensemble";valid=all(a.valid);end
        positive=all(isfinite(raw))&&raw(1)>0;hit=any(abs(bounded-raw)>1e-12);if s>n,hit=any(abs(a.clipped-a.raw)>1e-12,'all');end
        for post=1:2
            p=raw;processing="raw";if post==2,p=bounded;processing="common_clip";end
            finite=all(isfinite(p));r=struct('case_id',row.trial_id,'object_id',row.object_id,'condition',row.condition,'jitter_seed',0, ...
                'train_budget',a.budget,'method',string(a.name),'model_seed',seed,'model_kind',kind,'postprocessing',processing, ...
                'true_mass_kg',truth(1),'true_cx_m',truth(2),'true_cz_m',truth(3),'pred_mass_kg',p(1),'pred_cx_m',p(2),'pred_cz_m',p(3), ...
                'finite_prediction',finite,'model_valid',valid,'accepted',finite&&valid&&positive&&physical,'physical_success',physical, ...
                'steady_usable',F.steady.usable,'physics_usable',F.physics.usable,'teacher_accepted',F.physics.teacher_accepted,'raw_positive_mass',positive,'bounds_hit',hit);
            if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        end
    end
end
T=struct2table(rows);
end
