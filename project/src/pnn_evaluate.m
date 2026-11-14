function info=pnn_evaluate(D,spec,run_dir)
%PNN_EVALUATE Locked tests, full coverage and object-paired inference.
assert(all(string(D.split)=="test"),'pnn:EvalSplit','Evaluation accepts test rows only.');
lock=jsondecode(fileread(fullfile(run_dir,'MODEL_LOCK.json')));
bundle_file=fullfile(run_dir,'model_bundle.mat');
assert(~lock.selection_uses_test&&strcmp(lock.bundle_sha256,prc_file_hash(bundle_file)), ...
    'pnn:EvalLock','Missing or changed locked model.');
saved=load(bundle_file,'bundle');bundle=saved.bundle;
assert(isfield(D,'plan_signature')&&strcmp(D.plan_signature,lock.plan_signature), ...
    'pnn:EvalDataPlan','Test feature plan does not match the model lock.');
dataset_hash=pnn_model_hash(D);
donefile=fullfile(run_dir,'EVALUATION_COMPLETE.json');
if isfile(donefile)
    info=jsondecode(fileread(donefile));
    assert(strcmp(info.bundle_sha256,lock.bundle_sha256),'pnn:EvalIdentity','Evaluation model changed.');
    assert(strcmp(info.dataset_hash,dataset_hash),'pnn:EvalIdentity','Evaluation dataset changed.');
    for j=1:numel(info.outputs)
        assert(strcmp(prc_file_hash(info.outputs(j).path),info.outputs(j).sha256),'pnn:EvalIntegrity','Evaluation output changed.');
    end
    return
end
methods=string({bundle.methods.name});nm=numel(methods);n=size(D.theta,1);
assert(numel(unique(D.trial_id))==n,'pnn:EvalIDs','Duplicate trials.');
directory=fullfile(run_dir,'evaluation');if ~isfolder(directory),mkdir(directory);end
P=nan(n,3,nm);A=false(n,nm);C=false(n,nm);
signature=struct('bundle_sha256',lock.bundle_sha256,'plan_signature',lock.plan_signature,'dataset_hash',dataset_hash, ...
    'trial_id',D.trial_id,'object_id',D.object_id,'condition',string(D.condition));
for j=1:nm
    file=fullfile(directory,[char(methods(j)) '_predictions.mat']);
    if pnn_checkpoint('exists',file)
        S=pnn_checkpoint('read',file);
        assert(isequaln(S.signature,signature)&&strcmp(S.method,methods(j)), ...
            'pnn:PredictionIdentity','Prediction checkpoint identity changed.');
        p=S.prediction;detail=S.detail;
    else
        [p,detail]=pnn_predict(bundle,D,char(methods(j)));
        pnn_checkpoint('write',file,struct('signature',signature,'method',char(methods(j)), ...
            'prediction',p,'detail',detail));
    end
    assert(isequal(size(p),[n 3]),'pnn:PredictionSize','Prediction has wrong shape.');
    P(:,:,j)=p;A(:,j)=logical(detail.accepted(:))&all(isfinite(p),2);
    C(:,j)=all(isfinite(p),2)&any(p<spec.bounds(:,1).'|p>spec.bounds(:,2).',2);
    prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('done_methods',j,'total_methods',nm,'updated_utc',pnn_utc()));
end
conditions=unique(string(D.condition),'stable');nc=numel(conditions);
summary=struct([]);prediction_tables=cell(nm*2,1);deltas=struct([]);
baseline=find(methods=="ridge13");assert(isscalar(baseline),'pnn:Baseline','Expected ridge13.');
ridge_baselines=find(ismember(methods,["ridge13","ridgeAug","interactionRidge"]));
assert(numel(ridge_baselines)==3,'pnn:Baseline','Expected all three ridge comparators.');
primary=string(bundle.primary_method);assert(isscalar(primary)&&ismember(primary,methods),'pnn:Primary','No locked primary method.');
table_index=0;original_rng=rng;restore_rng=onCleanup(@()rng(original_rng)); %#ok<NASGU>
for post=1:2
    processing="raw";Q=P;
    if post==2
        processing="common_clip";
        for j=1:nm
            finite_raw=all(isfinite(P(:,:,j)),2);
            Q(finite_raw,:,j)=min(max(P(finite_raw,:,j),spec.bounds(:,1).'),spec.bounds(:,2).');
        end
    end
    for j=1:nm
        q=Q(:,:,j);mass=abs(q(:,1)-D.theta(:,1))*1000;
        com=sqrt(sum((q(:,2:3)-D.theta(:,2:3)).^2,2))*1000;
        finite=all(isfinite(q),2);table_index=table_index+1;
        prediction_tables{table_index}=table(D.trial_id(:),D.object_id(:),string(D.condition(:)), ...
            repmat(methods(j),n,1),repmat(processing,n,1),D.theta(:,1),D.theta(:,2),D.theta(:,3), ...
            q(:,1),q(:,2),q(:,3),finite,A(:,j),C(:,j),mass,com, ...
            'VariableNames',{'trial_id','object_id','condition','method','postprocessing', ...
            'true_mass_kg','true_cx_m','true_cz_m','mass_kg','cx_m','cz_m','finite','accepted','bounds_hit', ...
            'mass_abs_error_g','planar_com_distance_mm'});
        for k=1:nc
            ix=string(D.condition)==conditions(k);valid=ix&finite;accepted=valid&A(:,j);
            assert(numel(unique(D.object_id(ix)))==sum(ix),'pnn:RepeatedObject','Expected one trial per object and condition.');
            row=struct('method',methods(j),'condition',conditions(k),'postprocessing',processing, ...
                'planned_n',sum(ix),'finite_n',sum(valid),'accepted_n',sum(accepted), ...
                'failed_n',sum(ix&~finite),'clipped_n',sum(ix&C(:,j)), ...
                'finite_coverage',sum(valid)/sum(ix),'accepted_coverage',sum(accepted)/sum(ix), ...
                'mass_mae_g',avg(mass(valid)),'mass_rmse_g',sqrt(avg(mass(valid).^2)), ...
                'mass_p95_g',percent(mass(valid),95),'mass_max_g',maximum(mass(valid)), ...
                'planar_com_mean_distance_mm',avg(com(valid)),'planar_com_p95_distance_mm',percent(com(valid),95), ...
                'planar_com_max_distance_mm',maximum(com(valid)), ...
                'accepted_mass_mae_g',avg(mass(accepted)),'accepted_planar_com_mean_distance_mm',avg(com(accepted)));
            summary=append(summary,row);
            for comparator=ridge_baselines
            if j==comparator,continue,end
            pb=Q(:,:,comparator);basefinite=all(isfinite(pb),2);pair=ix&finite&basefinite;
            ids=D.object_id(pair);[~,order]=sort(ids);
            e0=[abs(pb(pair,1)-D.theta(pair,1))*1000, ...
                sqrt(sum((pb(pair,2:3)-D.theta(pair,2:3)).^2,2))*1000];
            e1=[mass(pair),com(pair)];difference=e1(order,:)-e0(order,:);
            rng(spec.bootstrap_seed,'twister');boot=paired_bootstrap(difference,spec.bootstrap_replicates);
            metrics=["mass_mae_g","planar_com_mean_distance_mm"];
            for metric=1:2
                b=boot(:,metric);values=difference(:,metric);family_upper=percent(b,100*(1-.05/8));
                dr=struct('method',methods(j),'baseline',methods(comparator),'condition',conditions(k), ...
                    'postprocessing',processing,'metric',metrics(metric),'planned_n',sum(ix), ...
                    'paired_n',sum(pair),'delta_mean',avg(values),'ci95_lower',percent(b,2.5), ...
                    'ci95_upper',percent(b,97.5),'primary_method',methods(j)==primary, ...
                    'bonferroni8_one_sided95_upper',family_upper,'bootstrap_replicates',spec.bootstrap_replicates, ...
                    'bonferroni24_one_sided95_upper',percent(b,100*(1-.05/24)), ...
                    'accepted_n',sum(ix&A(:,j)),'baseline_accepted_n',sum(ix&A(:,comparator)), ...
                    'all_planned_pairs_finite',sum(pair)==sum(ix));
                deltas=append(deltas,dr);
            end
            end
        end
    end
end
T=struct2table(summary);U=struct2table(deltas);R=vertcat(prediction_tables{:});
write_table(T,fullfile(run_dir,'summary.csv'));write_table(U,fullfile(run_dir,'paired_intervals.csv'));
write_table(R,fullfile(run_dir,'predictions.csv'));
raw=U.method==primary&U.postprocessing=="raw"&U.baseline=="ridge13";
strict=sum(raw)==8&&all(U.bonferroni8_one_sided95_upper(raw)<0)&& ...
    all(U.all_planned_pairs_finite(raw))&&all(U.accepted_n(raw)>=U.baseline_accepted_n(raw));
allridge=U.method==primary&U.postprocessing=="raw";
strict_all=sum(allridge)==24&&all(U.bonferroni24_one_sided95_upper(allridge)<0)&& ...
    all(U.all_planned_pairs_finite(allridge))&&all(U.accepted_n(allridge)>=U.baseline_accepted_n(allridge));
conclusion=struct('schema','pnn_primary_comparison_v1','primary_method',char(primary),'baseline','ridge13', ...
    'rule','All eight raw endpoint one-sided Bonferroni95 upper limits below zero, full finite pairing, no reduced accepted coverage.', ...
    'all_endpoint_superiority_supported',strict,'selection_uses_test',false, ...
    'all_three_ridge_superiority_supported',strict_all, ...
    'all_three_ridge_rule','All24 primary-vs-ridge13/ridgeAug/interactionRidge raw endpoint Bonferroni95 upper limits below zero, full pairing and no reduced coverage.', ...
    'interpretation','Failure of this rule is not equivalence/noninferiority and does not negate individual-condition differences.', ...
    'bootstrap_unit','independent payload object','n_unique_test_objects',numel(unique(D.object_id)), ...
    'scope',spec.scope);
prc_write_json(fullfile(run_dir,'primary_comparison.json'),conclusion);
names={'summary.csv','paired_intervals.csv','predictions.csv','primary_comparison.json'};
outputs=repmat(struct('path','','sha256',''),numel(names),1);
for j=1:numel(names),outputs(j).path=fullfile(run_dir,names{j});outputs(j).sha256=prc_file_hash(outputs(j).path);end
info=struct('schema','pnn_evaluation_complete_v1','completed_utc',pnn_utc(),'bundle_sha256',lock.bundle_sha256,'dataset_hash',dataset_hash, ...
    'plan_signature',lock.plan_signature,'planned_trials',n,'unique_objects',numel(unique(D.object_id)), ...
    'methods',nm,'primary_method',char(primary),'all_endpoint_superiority_supported',strict, ...
    'all_three_ridge_superiority_supported',strict_all,'outputs',outputs);
prc_write_json(donefile,info);
end
function B=paired_bootstrap(difference,nboot)
n=size(difference,1);B=nan(nboot,2);if n==0,return,end
for first=1:100:nboot
    ids=first:min(first+99,nboot);indices=randi(n,n,numel(ids));
    for j=1:2,v=difference(:,j);B(ids,j)=mean(v(indices),1).';end
end
end
function a=append(a,b)
if isempty(a),a=b;else,a(end+1)=b;end
end
function v=avg(x)
v=NaN;if ~isempty(x),v=mean(x);end
end
function v=percent(x,p)
v=NaN;if ~isempty(x)&&all(isfinite(x)),v=prctile(x,p);end
end
function v=maximum(x)
v=NaN;if ~isempty(x),v=max(x);end
end
function write_table(T,file)
temp=[file '.' char(java.util.UUID.randomUUID()) '.tmp'];
writetable(T,temp,'FileType','text');[ok,msg]=movefile(temp,file,'f');assert(ok,'pnn:TableWrite','%s',msg);
end
