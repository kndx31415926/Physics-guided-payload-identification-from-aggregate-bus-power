function info=psf_evaluate(run_dir,cfg,spec,models)
% Locked fitting precedes loading the development evaluation table or obs.
lockpath=fullfile(run_dir,'LOCKED_SELECTION_BEFORE_EVALUATION.mat');assert(isfile(lockpath),'psf:Lock','Selection must be locked.');
L=load(lockpath,'lock');assert(isequaln(L.lock.key,models.key)&&~models.test_used_for_selection,'psf:Lock','Invalid lock.');
P=load(fullfile(run_dir,'evaluation_plan.mat'),'evaluation');T=P.evaluation;N=height(T);tables=cell(N,1);reused=0;
key=struct('model_sha256',prc_file_hash(fullfile(run_dir,'models.mat')),'evaluation_plan_sha256',prc_file_hash(fullfile(run_dir,'evaluation_plan.mat')));
folder=fullfile(run_dir,'evaluation_checkpoints');if ~isfolder(folder),mkdir(folder);end
for i=1:N
    row=T(i,:);file=fullfile(folder,sprintf('case_%06d.mat',i));record_hash=prc_file_hash(char(row.record_path));
    if isfile(file)
        S=load(file,'checkpoint');cp=S.checkpoint;
        assert(isequaln(cp.key,key)&&cp.case_id==i&&strcmp(cp.record_hash,record_hash),'psf:ResumeMismatch','Evaluation checkpoint mismatch.');reused=reused+1;
    else
        F=psf_load_case(row,cfg,spec);predictions=psf_predict(models,F,cfg);
        % Ground truth enters scoring after all observation-only predictions.
        truth=[row.mass_kg row.cx_m row.cz_m];rows=prediction_rows(row,predictions,truth,F);
        cp=struct('key',key,'case_id',i,'record_hash',record_hash,'rows',rows);pgar_model_atomic_save(file,struct('checkpoint',cp));
    end
    tables{i}=cp.rows;
    if mod(i,25)==0||i==N
        prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('phase','evaluating','done',i,'total',N,'reused',reused,'selection_locked',true));
        fprintf('PSF evaluation %d/%d, reused %d.\n',i,N,reused);
    end
end
R=vertcat(tables{:});S=psf_summarize(R);writetable(R,fullfile(run_dir,'predictions.csv'));writetable(S,fullfile(run_dir,'summary.csv'));
info=struct('planned_cases',N,'unique_objects',numel(unique(T.object_id)),'prediction_rows',height(R),'summary_rows',height(S), ...
    'reused_checkpoints',reused,'study_role',spec.study_role,'inference_scope','Descriptive development diagnostic only; no confirmatory p-values or CIs.');
pgar_model_atomic_save(fullfile(run_dir,'results.mat'),struct('info',info,'summary',S));
end
function T=prediction_rows(row,M,truth,F)
rows=struct([]);
for m=1:numel(M)
    a=M(m);n=size(a.raw,1);
    for s=1:n+(n>1)
        seed=0;kind="deterministic";
        if s<=n
            raw=a.raw(s,:);bounded=a.clipped(s,:);seed=a.seeds(s);if seed~=0,kind="single";end
        else,raw=mean(a.raw,1);bounded=mean(a.clipped,1);kind="ensemble";end
        positive=all(isfinite(raw))&&raw(1)>0;hit=any(abs(bounded-raw)>1e-12);
        if s>n,hit=any(abs(a.clipped-a.raw)>1e-12,'all');end
        for post=1:2
            p=raw;processing="raw";if post==2,p=bounded;processing="common_clip";end
            finite=all(isfinite(p));valid=a.valid;accepted=finite&&valid&&positive&&F.physical_success;
            r=struct('case_id',row.case_id,'object_id',row.object_id,'condition',row.condition,'jitter_seed',row.jitter_seed, ...
                'train_budget',a.budget,'method',string(a.name),'model_seed',seed,'model_kind',kind,'postprocessing',processing, ...
                'true_mass_kg',truth(1),'true_cx_m',truth(2),'true_cz_m',truth(3),'pred_mass_kg',p(1),'pred_cx_m',p(2),'pred_cz_m',p(3), ...
                'finite_prediction',finite,'model_valid',valid,'accepted',accepted,'physical_success',F.physical_success, ...
                'steady_usable',F.steady.usable,'physics_usable',F.physics.usable,'teacher_accepted',F.physics.teacher_accepted, ...
                'raw_positive_mass',positive,'bounds_hit',hit);
            if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        end
    end
end
T=struct2table(rows);
end
