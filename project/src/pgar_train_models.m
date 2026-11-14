function info=pgar_train_models(run_dir,cfg,spec)
%PGAR_TRAIN_MODELS Resumable supervised physical-initialization/residual study.
% Formal defaults: new 600/150/300 full-servo objects; nested 72/240/600
% training budgets. The caller generates data_plan.mat and per-object trials.
% No test trial is loaded until ALL validation-selected candidates are locked.
% Only progress_training.json is managed here; root status.json is untouched.
run_dir=char(run_dir);spec=normalize_spec(spec);maxNumCompThreads(1);
try
    info=run_training(run_dir,cfg,spec);
catch err
    progress(run_dir,'failed',struct('identifier',err.identifier,'message',err.message));
    rethrow(err);
end
end

function info=run_training(root,cfg,spec)
P=load(fullfile(root,'data_plan.mat'),'objects','cfg','spec');O=P.objects;
assert(istable(O)&&all(ismember({'object_id','split','mass_kg','cx_m','cz_m'},O.Properties.VariableNames)), ...
    'pgar:Plan','Invalid objects table.');
assert(isequaln(P.cfg,cfg),'pgar:Config','Passed cfg differs from saved data plan.');
O.split=string(O.split);ids=double(O.object_id);N=height(O);
assert(numel(unique(ids))==N&&all(ids>0&ids==fix(ids))&& ...
    all(ismember(O.split,["train","validation","test"])), ...
    'pgar:Plan','Object IDs/splits are invalid.');
T=[O.mass_kg O.cx_m O.cz_m];assert(all(isfinite(T),'all'),'pgar:Plan','Nonfinite object labels.');
trainplan=find(O.split=="train");valplan=find(O.split=="validation");testplan=find(O.split=="test");
assert(numel(trainplan)>=max(spec.train_sizes)&&~isempty(valplan)&&~isempty(testplan), ...
    'pgar:Plan','Not enough prespecified objects.');
trialids=ids;if ismember('trial_id',O.Properties.VariableNames),trialids=double(O.trial_id);end
assert(numel(unique(trialids))==N,'pgar:Plan','Trial IDs must be unique.');
stamps=struct('trial_id',{},'bytes',{},'datenum',{});
for i=1:N
    d=dir(trial_path(root,trialids(i)));
    assert(~isempty(d),'pgar:MissingTrial','Missing planned trial %d; generation must finish first.',trialids(i));
    stamps(i)=struct('trial_id',trialids(i),'bytes',d.bytes,'datenum',d.datenum); %#ok<AGROW>
end
contract=struct('schema','pgar_training_contract_v1','cfg',cfg,'spec',spec, ...
    'objects',O,'trial_stamps',stamps,'source',source_manifest());
contractpath=fullfile(root,'TRAINING_CONTRACT.mat');
if exist(contractpath,'file')
    old=load(contractpath,'contract');
    assert(isequaln(old.contract,contract),'pgar:ResumeMismatch', ...
        'Configuration, plan, trial files or training sources changed; use a new run directory.');
else
    pgar_model_atomic_save(contractpath,struct('contract',contract));
end
cache_dir=fullfile(root,'features');model_dir=fullfile(root,'models','candidates');
if ~exist(cache_dir,'dir'),mkdir(cache_dir);end
if ~exist(model_dir,'dir'),mkdir(model_dir);end
snapshot=fullfile(root,'training_source');if ~exist(snapshot,'dir'),mkdir(snapshot);end
for k=1:numel(contract.source),copyfile(contract.source(k).path,snapshot);end
names={'encoder_only','encoder_plus_power','power_only','physics_residual_nn'};
nb=numel(spec.train_sizes);ns=numel(spec.network_seeds);nm=numel(names);
F=cell(N,1);status=empty_status(O,trialids);
pretest=[trainplan;valplan];progress(root,'caching_train_validation',struct('planned',numel(pretest)));
for k=1:numel(pretest)
    i=pretest(k);[F{i},status(i,:)]=cache_trial(root,cfg,spec,O(i,:),trialids(i),stamps(i));
    if mod(k,25)==0||k==numel(pretest)
        progress(root,'caching_train_validation',struct('done',k,'planned',numel(pretest)));
    end
end
writetable(status(pretest,:),fullfile(root,'trial_status_train_validation.csv'));
[Xq,Xp,Xr,base]=feature_matrices(F,N);eligible=status.feature_usable&status.physical_success;
val=valplan(eligible(valplan));assert(numel(val)>=2,'pgar:Data','Fewer than two usable validation objects.');
inputs={Xq,[Xq Xp],Xp,Xr};students=cell(nb,nm,ns);selectionrows=struct([]);coverage=struct([]);
all_train=cell(nb,1);total_candidates=nb*nm*ns*numel(spec.layers)*numel(spec.lambdas);done=0;
for b=1:nb
    n=spec.train_sizes(b);planned=trainplan(1:n);train=planned(eligible(planned));all_train{b}=train;
    assert(numel(train)>=4,'pgar:Data','Fewer than four usable objects in budget %d.',n);
    coverage=add_coverage(coverage,n,'train',planned,train,status);
    coverage=add_coverage(coverage,n,'validation',valplan,val,status);
    for m=1:nm
        X=inputs{m};keep=std(X(train,:),0,1)>1e-10;
        assert(any(keep),'pgar:Data','No varying training features for %s.',names{m});
        offset=zeros(N,3);if m==4,offset=base;end
        target=(T-offset)./spec.scale;
        for s=1:ns
            seed=spec.network_seeds(s);best=Inf;learner=[];
            for l=1:numel(spec.layers)
                for w=1:numel(spec.lambdas)
                    filename=sprintf('n%06d_%s_seed%d_l%d_w%d.mat',n,names{m},seed,l,w);
                    path=fullfile(model_dir,filename);
                    key=struct('budget',n,'method',names{m},'seed',seed,'layers',spec.layers{l}, ...
                        'lambda',spec.lambdas(w),'columns',keep,'train_ids',ids(train),'validation_ids',ids(val));
                    if exist(path,'file')
                        saved=load(path,'checkpoint');checkpoint=saved.checkpoint;
                        assert(isequaln(checkpoint.key,key),'pgar:ResumeMismatch','Candidate key mismatch.');
                    else
                        checkpoint=fit_candidate(X(:,keep),target,T,offset,train,val,cfg,spec,key);
                        pgar_model_atomic_save(path,struct('checkpoint',checkpoint));
                    end
                    done=done+1;row=checkpoint.selection;
                    row.checkpoint_path=path;selectionrows=append_struct(selectionrows,row);
                    if strcmp(checkpoint.status,'complete')&&row.validation_normalized_mse<best
                        best=row.validation_normalized_mse;
                        learner=struct('model',checkpoint.model,'columns',keep,'selection',row);
                    end
                    progress(root,'training',struct('candidates_done',done,'candidates_total',total_candidates, ...
                        'train_budget',n,'method',names{m},'seed',seed));
                end
            end
            assert(~isempty(learner),'pgar:Training','All candidates failed: n%d %s seed%d.',n,names{m},seed);
            students{b,m,s}=learner;
            fprintf('PGAR n%d %s seed%d selected %s lambda %.4g validation %.7g\n', ...
                n,names{m},seed,learner.selection.layers,learner.selection.lambda,best);
        end
    end
end
selections=struct2table(selectionrows);writetable(selections,fullfile(root,'validation_selection.csv'));
% This lock is written only after all budgets/modes/seeds have been selected.
% It exists on disk BEFORE cache_trial is ever called for a test object.
chosen=struct([]);
for b=1:nb,for m=1:nm,for s=1:ns
    chosen=append_struct(chosen,students{b,m,s}.selection);
end,end,end
lock=struct('schema','pgar_selection_lock_v1','created_at',timestamp(), ...
    'selection',struct2table(chosen),'train_sizes',spec.train_sizes, ...
    'deployment_train_size',spec.deployment_train_size,'network_seeds',spec.network_seeds, ...
    'test_object_ids',ids(testplan),'test_used_for_selection',false, ...
    'ensemble_rule','Equal average of every prespecified seed after per-seed bounds clipping.', ...
    'contract_path',contractpath);
lockpath=fullfile(root,'LOCKED_SELECTION_BEFORE_TEST.mat');
if exist(lockpath,'file')
    old=load(lockpath,'lock');
    assert(isequaln(old.lock.selection,lock.selection)&& ...
        isequaln(old.lock.test_object_ids,lock.test_object_ids), ...
        'pgar:ResumeMismatch','Selection differs from existing test lock.');
    lock=old.lock;
else
    pgar_model_atomic_save(lockpath,struct('lock',lock));
end
deployment=find(spec.train_sizes==spec.deployment_train_size,1);
models=reshape(students(deployment,4,:),1,ns);
bundle=struct('schema','pgar_residual_bundle_v1','cfg',cfg,'scale',spec.scale, ...
    'models',{models},'probe_id',spec.probe_id,'feature_schema','pgar_features_v1', ...
    'feature_scope','13 physical initialization/residual summaries; not raw waveform NN', ...
    'train_budget',spec.deployment_train_size,'training_object_ids',ids(all_train{deployment}), ...
    'validation_object_ids',ids(val),'network_seeds',spec.network_seeds, ...
    'known_bounds',cfg.ident.bounds,'power_coefficients',cfg.legacy.power.coefficients, ...
    'scope','Fixed nominal known robot and power model; m,cx,cz only; no wear or online update', ...
    'acceptance_scope','Observation and teacher heuristics; no certified accuracy guarantee', ...
    'selection_lock',lockpath,'summary_path',fullfile(root,'summary.csv'));
pgar_model_atomic_save(fullfile(root,'model_bundle.mat'),struct('bundle',bundle));
progress(root,'test_evaluation',struct('selection_locked',true,'planned',numel(testplan)));
for k=1:numel(testplan)
    i=testplan(k);[F{i},status(i,:)]=cache_trial(root,cfg,spec,O(i,:),trialids(i),stamps(i));
    if mod(k,25)==0||k==numel(testplan)
        progress(root,'test_evaluation',struct('done',k,'planned',numel(testplan),'selection_locked',true));
    end
end
[Xq,Xp,Xr,base]=feature_matrices(F,N);inputs={Xq,[Xq Xp],Xp,Xr};
eligible=status.feature_usable&status.physical_success;test=testplan(eligible(testplan));
assert(~isempty(test),'pgar:Data','No usable test objects; failed records are retained.');
rows=struct([]);ensembles=cell(nb,nm);
for b=1:nb
    n=spec.train_sizes(b);coverage=add_coverage(coverage,n,'test',testplan,test,status);
    for m=1:nm
        pred=nan(numel(test),3,ns);offset=zeros(numel(test),3);if m==4,offset=base(test,:);end
        X=inputs{m};
        for s=1:ns
            learner=students{b,m,s};
            pred(:,:,s)=clip(predict(learner.model,X(test,learner.columns)).*spec.scale+offset,cfg.ident.bounds);
            p=nan(numel(testplan),3);[~,position]=ismember(test,testplan);p(position,:)=pred(:,:,s);
            accepted=eligible(testplan);if m==4,accepted=accepted&status.teacher_accepted(testplan);end
            rows=add_predictions(rows,n,names{m},spec.network_seeds(s),testplan,ids,T,p,accepted,status);
        end
        ensemble=mean(pred,3);ensembles{b,m}=ensemble;
        p=nan(numel(testplan),3);p(position,:)=ensemble;
        rows=add_predictions(rows,n,names{m},0,testplan,ids,T,p,accepted,status);
    end
    train=all_train{b};p=repmat(mean(T(train,:),1),numel(testplan),1);
    rows=add_predictions(rows,n,'training_mean',0,testplan,ids,T,p,true(numel(testplan),1),status);
    p=nan(numel(testplan),3);p(position,:)=base(test,:);
    rows=add_predictions(rows,n,'physics_inverse',0,testplan,ids,T,p, ...
        eligible(testplan)&status.teacher_accepted(testplan),status);
end
R=struct2table(rows);S=summarize_predictions(R);seed_summary=summarize_seeds(S);
CI=paired_bootstrap(ensembles,base(test,:),T(test,:),spec,numel(testplan));
writetable(R,fullfile(root,'predictions.csv'));writetable(S,fullfile(root,'summary.csv'));
writetable(seed_summary,fullfile(root,'seed_summary.csv'));writetable(CI,fullfile(root,'paired_bootstrap.csv'));
writetable(status,fullfile(root,'trial_status.csv'));writetable(struct2table(coverage),fullfile(root,'coverage.csv'));
results=struct('spec',spec,'summary',S,'seed_summary',seed_summary,'paired_bootstrap',CI, ...
    'students',{students},'train_rows',{all_train},'validation_rows',val,'test_rows',test, ...
    'objects',O,'selection_lock',lock,'conditional_inference', ...
    'Bootstrap conditions on this split and trained models; no training-set/resimulation uncertainty.');
pgar_model_atomic_save(fullfile(root,'training_results.mat'),struct('results',results));
info=struct('complete',true,'run_dir',root,'deployment_train_size',spec.deployment_train_size, ...
    'model_bundle_path',fullfile(root,'model_bundle.mat'),'summary_path',fullfile(root,'summary.csv'), ...
    'predictions_path',fullfile(root,'predictions.csv'),'report_path',fullfile(root,'REPORT.txt'), ...
    'summary',S,'planned_objects',N,'usable_test_objects',numel(test),'planned_test_objects',numel(testplan));
write_report(root,S,status,spec,numel(testplan),numel(test));
completion=rmfield(info,'summary');completion.completed_at=timestamp();
atomic_text(fullfile(root,'TRAINING_COMPLETE.json'),jsonencode(completion,'PrettyPrint',true));
progress(root,'complete',completion);
end

function checkpoint=fit_candidate(X,Y,T,offset,train,val,cfg,spec,key)
row=struct('train_budget',key.budget,'train_used',numel(train),'validation_used',numel(val), ...
    'method',key.method,'seed',key.seed,'layers',mat2str(key.layers),'lambda',key.lambda, ...
    'feature_count',sum(key.columns),'validation_normalized_mse',Inf, ...
    'stop_iterations',NaN,'best_validation_iteration',NaN,'stopping_reason','', ...
    'candidate_status','failed','error_identifier','','error_message','');
checkpoint=struct('schema','pgar_candidate_v1','key',key,'status','failed','model',[],'selection',row);
try
    rng(key.seed,'twister');
    model=fitrnet(X(train,:),Y(train,:),'LayerSizes',key.layers,'Activations','tanh', ...
        'Standardize',true,'Lambda',key.lambda,'Verbose',0,'IterationLimit',spec.iterations, ...
        'ValidationData',{X(val,:),Y(val,:)},'ValidationPatience',spec.patience);
    p=clip(predict(model,X(val,:)).*spec.scale+offset(val,:),cfg.ident.bounds);
    loss=mean(((p-T(val,:))./spec.scale).^2,'all');assert(isfinite(loss),'pgar:Fit','Nonfinite validation loss.');
    C=model.ConvergenceInfo;H=C.History;
    if istable(H),[~,ix]=min(H.ValidationLoss);iteration=H.Iteration(ix);
    else,[~,ix]=min([H.ValidationLoss]);iteration=H(ix).Iteration;end
    row.validation_normalized_mse=loss;row.stop_iterations=C.Iterations;
    row.best_validation_iteration=iteration;row.stopping_reason=char(C.ConvergenceCriterion);
    row.candidate_status='complete';checkpoint.status='complete';checkpoint.model=model;
catch err
    row.error_identifier=err.identifier;row.error_message=err.message;
end
checkpoint.selection=row;
end

function [f,row]=cache_trial(root,cfg,spec,object,trialid,stamp)
path=fullfile(root,'features',sprintf('trial_%06d.mat',trialid));
key=struct('object_id',object.object_id,'split',char(object.split),'probe_id',spec.probe_id,'stamp',stamp);
if exist(path,'file')
    saved=load(path,'cached');cached=saved.cached;
    assert(isequaln(cached.key,key),'pgar:CacheMismatch','Feature cache key differs.');
    f=cached.features;row=cached.status;return
end
row=empty_status(object,trialid);f=[];
try
    loaded=load(trial_path(root,trialid),'record');r=loaded.record;
    assert(r.object_id==object.object_id&&r.trial_id==trialid&& ...
        strcmp(string(r.split),object.split)&&strcmp(string(r.probe_id),string(spec.probe_id)), ...
        'pgar:Record','Record identity does not match plan.');
    if ~isempty(r.error)
        if isstruct(r.error)&&isfield(r.error,'message')
            error('pgar:SimulationFailure','Saved simulation error: %s',r.error.message);
        else
            error('pgar:SimulationFailure','Trial contains a saved simulation error.');
        end
    end
    % truth contributes an audit flag only; it never enters feature extraction.
    if isstruct(r.truth)&&isfield(r.truth,'physical_success')
        row.physical_success=logical(r.truth.physical_success);
    elseif isstruct(r.truth)&&isfield(r.truth,'success')
        row.physical_success=logical(r.truth.success);
    end
    f=pgar_model_features(cfg,r.obs,spec.scale,spec.probe_id);
    row.feature_usable=f.usable;row.teacher_accepted=f.teacher_accepted;
    row.error_message=string(f.error_message);row.reasons=string(strjoin(f.reasons,';'));
catch err
    row.error_identifier=string(err.identifier);row.error_message=string(err.message);
end
cached=struct('schema','pgar_trial_cache_v1','key',key,'features',f,'status',row);
pgar_model_atomic_save(path,struct('cached',cached));
end

function status=empty_status(O,trialids)
n=height(O);status=table(double(trialids(:)),double(O.object_id),string(O.split), ...
    false(n,1),false(n,1),false(n,1),strings(n,1),strings(n,1),strings(n,1), ...
    'VariableNames',{'trial_id','object_id','split','physical_success','feature_usable', ...
    'teacher_accepted','error_identifier','error_message','reasons'});
end
function [Xq,Xp,Xr,base]=feature_matrices(F,N)
Xq=nan(N,128);Xp=nan(N,40);Xr=nan(N,13);base=nan(N,3);
for i=1:N
    if ~isempty(F{i})&&F{i}.usable
        Xq(i,:)=F{i}.q;Xp(i,:)=F{i}.power;Xr(i,:)=F{i}.residual;base(i,:)=F{i}.base;
    end
end
end
function rows=add_predictions(rows,budget,method,seed,planned,ids,T,p,accepted,status)
for k=1:numel(planned)
    i=planned(k);e=1000*(p(k,:)-T(i,:));available=all(isfinite(p(k,:)));
    row=struct('train_budget',budget,'method',method,'seed',seed,'object_id',ids(i), ...
        'prediction_available',available,'accepted',logical(accepted(k))&&available, ...
        'physical_success',status.physical_success(i),'feature_usable',status.feature_usable(i), ...
        'teacher_accepted',status.teacher_accepted(i), ...
        'mass_true_kg',T(i,1),'cx_true_m',T(i,2),'cz_true_m',T(i,3), ...
        'mass_est_kg',p(k,1),'cx_est_m',p(k,2),'cz_est_m',p(k,3), ...
        'mass_error_g',e(1),'cx_error_mm',e(2),'cz_error_mm',e(3));
    rows=append_struct(rows,row);
end
end
function S=summarize_predictions(R)
keys=unique(R(:,{'train_budget','method','seed'}),'rows','stable');rows=struct([]);
for k=1:height(keys)
    ix=R.train_budget==keys.train_budget(k)&strcmp(R.method,keys.method{k})&R.seed==keys.seed(k);
    V=R(ix,:);E=[V.mass_error_g V.cx_error_mm V.cz_error_mm];finite=all(isfinite(E),2);
    mae=mean(abs(E(finite,:)),1);rmse=sqrt(mean(E(finite,:).^2,1));mx=max(abs(E(finite,:)),[],1);
    ae=mean(abs(E(V.accepted,:)),1);if isempty(mx),mx=nan(1,3);end
    row=struct('train_budget',keys.train_budget(k),'method',keys.method{k},'seed',keys.seed(k), ...
        'planned_test_n',height(V),'predicted_n',sum(finite),'accepted_n',sum(V.accepted), ...
        'prediction_coverage',mean(finite),'acceptance_coverage',mean(V.accepted), ...
        'mass_mae_g',mae(1),'cx_mae_mm',mae(2),'cz_mae_mm',mae(3), ...
        'mass_rmse_g',rmse(1),'cx_rmse_mm',rmse(2),'cz_rmse_mm',rmse(3), ...
        'mass_max_g',mx(1),'cx_max_mm',mx(2),'cz_max_mm',mx(3), ...
        'accepted_mass_mae_g',ae(1),'accepted_cx_mae_mm',ae(2),'accepted_cz_mae_mm',ae(3));
    rows=append_struct(rows,row);
end
S=struct2table(rows);
end
function Z=summarize_seeds(S)
S=S(S.seed~=0,:);keys=unique(S(:,{'train_budget','method'}),'rows','stable');rows=struct([]);
for k=1:height(keys)
    ix=S.train_budget==keys.train_budget(k)&strcmp(S.method,keys.method{k});
    A=[S.mass_mae_g(ix) S.cx_mae_mm(ix) S.cz_mae_mm(ix)];mu=mean(A,1);sd=std(A,0,1);
    row=struct('train_budget',keys.train_budget(k),'method',keys.method{k},'seed_count',sum(ix), ...
        'mass_mae_mean_g',mu(1),'mass_mae_seed_sd_g',sd(1), ...
        'cx_mae_mean_mm',mu(2),'cx_mae_seed_sd_mm',sd(2), ...
        'cz_mae_mean_mm',mu(3),'cz_mae_seed_sd_mm',sd(3));rows=append_struct(rows,row);
end
Z=struct2table(rows);
end
function CI=paired_bootstrap(E,base,T,spec,planned_n)
comparisons={1,2,'adding_power';2,4,'residual_vs_encoder_plus_power';5,4,'residual_vs_physics'};
rows=struct([]);rng(spec.bootstrap_seed,'twister');n=size(T,1);draw=randi(n,n,spec.bootstrap_n);
parameters={'mass','cx','cz'};
for b=1:numel(spec.train_sizes)
    for c=1:size(comparisons,1)
        a=comparisons{c,1};z=comparisons{c,2};
        if a==5,A=base;else,A=E{b,a};end
        D=1000*(abs(A-T)-abs(E{b,z}-T));
        for h=1:3
            v=D(:,h);means=mean(v(draw),1);q=prctile(means,[2.5 97.5]);
            row=struct('train_budget',spec.train_sizes(b),'contrast',comparisons{c,3}, ...
                'parameter',parameters{h},'mean_error_reduction',mean(v), ...
                'lower95',q(1),'upper95',q(2),'paired_objects',n,'planned_test_objects',planned_n, ...
                'bootstrap_replicates',spec.bootstrap_n,'unit','g_or_mm', ...
                'scope','All paired finite candidates; conditional on this split and trained models; no multiplicity correction');
            rows=append_struct(rows,row);
        end
    end
end
CI=struct2table(rows);
end
function rows=add_coverage(rows,budget,split,planned,used,status)
row=struct('train_budget',budget,'split',split,'planned_n',numel(planned),'used_n',numel(used), ...
    'physical_failure_n',sum(~status.physical_success(planned)), ...
    'feature_unusable_n',sum(~status.feature_usable(planned)), ...
    'teacher_rejected_n',sum(~status.teacher_accepted(planned)), ...
    'used_teacher_rejected_n',sum(~status.teacher_accepted(used)), ...
    'selection_rule','Fixed planned prefix; retain audit failures; common finite-feature cohort; no replacements');
rows=append_struct(rows,row);
end
function rows=append_struct(rows,row)
if isempty(rows),rows=row;else,rows(end+1)=row;end
end
function p=clip(p,bounds)
p=min(max(p,bounds(:,1).'),bounds(:,2).');
end
function path=trial_path(root,id)
path=fullfile(root,'trials',sprintf('trial_%06d.mat',id));
end
function S=source_manifest()
files={'pgar_train_models','pgar_model_features','pgar_model_predict','pgar_model_atomic_save', ...
    'bpil_teacher','bpil_static_design','bpil_predict_power','bpil_make_plant'};
S=struct('name',{},'path',{},'text',{});
for k=1:numel(files)
    p=which(files{k});assert(~isempty(p),'pgar:Source','Missing %s.',files{k});
    S(k)=struct('name',files{k},'path',p,'text',fileread(p)); %#ok<AGROW>
end
end
function spec=normalize_spec(spec)
defaults=struct('train_sizes',[72 240 600],'network_seeds',[630101 630102 630103], ...
    'layers',{{[8],[16 8]}},'lambdas',[.001 .1],'iterations',800,'patience',30, ...
    'scale',[.14 .14 .036],'probe_id','probe_02','bootstrap_n',2000, ...
    'bootstrap_seed',630990,'deployment_train_size',600,'study_role','formal_confirmation');
fields=fieldnames(defaults);selected=defaults;
for k=1:numel(fields),if isfield(spec,fields{k}),selected.(fields{k})=spec.(fields{k});end,end
spec=selected;spec.train_sizes=double(spec.train_sizes(:).');spec.network_seeds=double(spec.network_seeds(:).');
spec.scale=double(spec.scale(:).');spec.probe_id=char(spec.probe_id);
assert(all(spec.train_sizes>=4&spec.train_sizes==fix(spec.train_sizes))&&all(diff(spec.train_sizes)>0)&& ...
    ismember(spec.deployment_train_size,spec.train_sizes),'pgar:Spec','Invalid train budgets/deployment budget.');
assert(numel(unique(spec.network_seeds))==numel(spec.network_seeds)&&~isempty(spec.network_seeds)&& ...
    all(spec.network_seeds>=0&spec.network_seeds==fix(spec.network_seeds)), 'pgar:Spec','Invalid seeds.');
assert(numel(spec.scale)==3&&all(isfinite(spec.scale))&&all(spec.scale>0)&& ...
    spec.iterations>=1&&spec.patience>=1&&spec.bootstrap_n>=1&& ...
    iscell(spec.layers)&&~isempty(spec.layers)&&~isempty(spec.lambdas), 'pgar:Spec','Invalid training specification.');
end
function write_report(root,S,status,spec,planned_test,used_test)
row=S(S.train_budget==spec.deployment_train_size&strcmp(S.method,'physics_residual_nn')&S.seed==0,:);
lines={sprintf('PGAR physical initialization + residual NN completed %s',timestamp()), ...
    sprintf('Study role: %s. Development fixtures are not independent confirmation data.',spec.study_role), ...
    sprintf('Prespecified deployment training budget: %d; equal average of %d seeds.',spec.deployment_train_size,numel(spec.network_seeds)), ...
    sprintf('Primary finite-candidate test MAE: %.6f g, %.6f mm cx, %.6f mm cz.',row.mass_mae_g,row.cx_mae_mm,row.cz_mae_mm), ...
    sprintf('Test planned %d; common usable %d; residual accepted %d.',planned_test,used_test,row.accepted_n), ...
    sprintf('All split audit counts: physical failures %d; feature unusable %d; teacher rejected %d.', ...
        sum(~status.physical_success),sum(~status.feature_usable),sum(~status.teacher_accepted)), ...
    'summary.csv reports ALL finite candidates and accepted-subset metrics separately; failures remain in predictions/trial_status.', ...
    'Training budgets are nested planned prefixes; failed objects are not replaced. All signal methods use the same finite-feature cohort.', ...
    'Every candidate is selected on independent validation objects. All budgets/seeds are locked before any test trajectory is loaded.', ...
    'fitrnet ValidationData/patience uses native best-validation weights; no seed is selected on test.', ...
    'Bootstrap units are test objects, conditional on this split and trained models; no retraining/resimulation uncertainty or multiplicity correction.', ...
    'Features are segment/plateau summaries, not raw waveform NN. Physical residual models use more model prior than signal-only methods.', ...
    'Fixed nominal known robot/power coefficients, rigid attachment, fixed probe02, planar m/cx/cz only; no 3D COM, wear, online update or hardware accuracy guarantee.', ...
    'Deployment: load model_bundle.mat bundle; out=pgar_model_predict(bundle,obs). Rejection returns theta=NaN; candidate_theta is diagnostic only.', ...
    'Artifacts: model_bundle.mat, summary.csv, seed_summary.csv, paired_bootstrap.csv, predictions.csv, trial_status.csv, coverage.csv, validation_selection.csv, LOCKED_SELECTION_BEFORE_TEST.mat.'};
atomic_text(fullfile(root,'REPORT.txt'),strjoin(lines,newline));
end
function progress(root,stage,details)
p=struct('stage',stage,'updated_at',timestamp(),'details',details);
atomic_text(fullfile(root,'progress_training.json'),jsonencode(p,'PrettyPrint',true));
end
function text=timestamp()
text=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
end
function atomic_text(path,contents)
folder=fileparts(path);if ~exist(folder,'dir'),mkdir(folder);end
temporary=[tempname(folder) '.tmp'];fid=fopen(temporary,'w','n','UTF-8');
assert(fid>=0,'pgar:IO','Cannot create temporary output.');
try
    fprintf(fid,'%s\n',contents);fclose(fid);[ok,msg]=movefile(temporary,path,'f');assert(ok,'pgar:IO','%s',msg);
catch err
    try,fclose(fid);catch,end
    if exist(temporary,'file'),delete(temporary);end
    rethrow(err);
end
end
