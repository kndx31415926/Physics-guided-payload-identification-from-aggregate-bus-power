function models=psf_train(run_dir,cfg,spec)
% Fit only training/validation plans; write lock before evaluating heldout.
key=struct('spec',spec,'training_plan_sha256',prc_file_hash(fullfile(run_dir,'training_plan.mat')), ...
    'input_manifest_sha256',prc_file_hash(fullfile(run_dir,'input_manifest.csv')), ...
    'source_manifest_sha256',prc_file_hash(fullfile(run_dir,'source_manifest.csv')));
model_path=fullfile(run_dir,'models.mat');lockpath=fullfile(run_dir,'LOCKED_SELECTION_BEFORE_EVALUATION.mat');
if isfile(model_path)
    S=load(model_path,'models');models=S.models;assert(isequaln(models.key,key),'psf:ResumeMismatch','Training inputs changed.');
    write_lock(lockpath,models);write_selected(run_dir,models);return
end
P=load(fullfile(run_dir,'training_plan.mat'),'training');T=P.training;N=height(T);
assert(all(ismember(T.split,["train","validation"])),'psf:Leakage','Training plan contains nontraining objects.');
featurefile=fullfile(run_dir,'training_features.mat');
if isfile(featurefile)
    S=load(featurefile,'cache');cache=S.cache;assert(isequaln(cache.key,key),'psf:ResumeMismatch','Feature cache changed.');
else
    X=nan(N,40);X48=nan(N,48);XR=nan(N,13);base=nan(N,3);physical=false(N,1);steady=physical;physics=physical;
    for i=1:N
        F=psf_load_case(T(i,:),cfg,spec);X(i,:)=F.steady.x;X48(i,:)=F.steady.x48;XR(i,:)=F.physics.residual;base(i,:)=F.physics.base;
        physical(i)=F.physical_success;steady(i)=F.steady.usable;physics(i)=F.physics.usable;
        if mod(i,25)==0||i==N,progress('features',i,N);end
    end
    cache=struct('key',key,'X',X,'X48',X48,'XR',XR,'base',base,'physical',physical,'steady',steady,'physics',physics);
    pgar_model_atomic_save(featurefile,struct('cache',cache));
end
Y=[T.mass_kg T.cx_m T.cz_m];train=find(T.split=="train");vplan=find(T.split=="validation");
common=cache.physical&cache.steady&cache.physics;val=vplan(common(vplan));assert(numel(val)>=2,'psf:Data','Too few validation objects.');
names={'steady_qps_nn48','steady_qp_nn40','steady_qps_ridge48','physics_residual_ridge13'};students=cell(numel(spec.train_sizes),4,numel(spec.network_seeds));
records=struct([]);train_used=zeros(numel(spec.train_sizes),1);candidate_dir=fullfile(run_dir,'candidates');if ~isfolder(candidate_dir),mkdir(candidate_dir);end
total=numel(spec.train_sizes)*(2*numel(spec.network_seeds)*numel(spec.layers)*numel(spec.lambdas)+2*numel(spec.lambdas));done=0;
for b=1:numel(spec.train_sizes)
    budget=spec.train_sizes(b);planned=train(1:budget);tr=planned(common(planned));train_used(b)=numel(tr);
    assert(numel(tr)>=4,'psf:Data','Too few usable training objects.');
    for m=1:4
        X=cache.X48;offset=zeros(N,3);if m==2,X=cache.X;elseif m==4,X=cache.XR;offset=cache.base;end
        keep=std(X(tr,:),0,1)>1e-10;assert(any(keep),'psf:Data','No varying inputs.');target=(Y-offset)./spec.scale;
        ns=numel(spec.network_seeds);nl=numel(spec.layers);if m>=3,ns=1;nl=1;end
        for s=1:ns
            seed=0;if m<=2,seed=spec.network_seeds(s);end
            best=Inf;chosen=[];
            for l=1:nl,for w=1:numel(spec.lambdas)
                layers=[];if m<=2,layers=spec.layers{l};end
                candidate_key=struct('run_key',key,'method',names{m},'train_budget',budget,'seed',seed, ...
                    'layers',layers,'lambda',spec.lambdas(w),'columns',keep,'train_ids',T.object_id(tr),'validation_ids',T.object_id(val));
                file=fullfile(candidate_dir,sprintf('n%d_%s_seed%d_l%d_w%d.mat',budget,names{m},seed,l,w));
                if isfile(file)
                    S=load(file,'checkpoint');cp=S.checkpoint;assert(isequaln(cp.key,candidate_key),'psf:ResumeMismatch','Candidate changed.');
                else
                    cp=fit_candidate(candidate_key,X(:,keep),target,Y,offset,tr,val,cfg,spec,m<=2);
                    pgar_model_atomic_save(file,struct('checkpoint',cp));
                end
                if isempty(records),records=cp.selection;else,records(end+1)=cp.selection;end %#ok<AGROW>
                if strcmp(cp.status,'complete')&&cp.selection.validation_normalized_mse<best
                    best=cp.selection.validation_normalized_mse;chosen=struct('kind',cp.kind,'model',cp.model,'columns',keep,'selection',cp.selection);
                end
                done=done+1;progress('training',done,total);
            end,end
            assert(~isempty(chosen),'psf:Training','All candidates failed for %s budget %d seed %d.',names{m},budget,seed);
            students{b,m,s}=chosen;
            fprintf('PSF n%d %s seed%d validation %.7g lambda %.3g\n',budget,names{m},seed,best,chosen.selection.lambda);
        end
    end
end
% Original physical-residual learners retain original validation selections.
R=load(fullfile(spec.source_dir,'training_results.mat'),'results');R=R.results;
reference=cell(numel(spec.train_sizes),numel(spec.network_seeds));
for b=1:numel(spec.train_sizes),bi=find(R.spec.train_sizes==spec.train_sizes(b));assert(isscalar(bi));
    for s=1:numel(spec.network_seeds),si=find(R.spec.network_seeds==spec.network_seeds(s));assert(isscalar(si));reference{b,s}=R.students{bi,4,si};end
end
models=struct('schema','psf_models_v1','key',key,'spec',spec,'students',{students},'reference',{reference}, ...
    'selection',struct2table(records),'train_used',train_used,'validation_used',numel(val),'training_common_eligible',common, ...
    'test_used_for_selection',false,'scope','DEVELOPMENT ONLY; matched steady q/P; reused previously inspected evaluation objects.');
writetable(models.selection,fullfile(run_dir,'validation_selection.csv'));
coverage=T(:,{'case_id','object_id','split'});coverage.physical_success=cache.physical;coverage.steady_usable=cache.steady;
coverage.physics_usable=cache.physics;coverage.common_training_eligible=common;writetable(coverage,fullfile(run_dir,'training_coverage.csv'));
groups=["train","validation"];coverage_rows=struct([]);
for g=1:numel(groups)
    use=T.split==groups(g);r=struct('split',groups(g),'planned_n',sum(use),'physical_success_n',sum(cache.physical(use)), ...
        'steady_usable_n',sum(cache.steady(use)),'physics_usable_n',sum(cache.physics(use)), ...
        'common_eligible_n',sum(common(use)),'excluded_n',sum(~common(use)));
    if isempty(coverage_rows),coverage_rows=r;else,coverage_rows(end+1)=r;end %#ok<AGROW>
end
writetable(struct2table(coverage_rows),fullfile(run_dir,'training_coverage_summary.csv'));
pgar_model_atomic_save(model_path,struct('models',models));write_lock(lockpath,models);write_selected(run_dir,models);
    function progress(phase,done,total)
        prc_write_json(fullfile(run_dir,'progress_training.json'),struct('phase',phase,'done',done,'total',total,'test_used',false));
    end
end
function cp=fit_candidate(key,X,Y,truth,offset,tr,val,cfg,spec,neural)
row=struct('method',string(key.method),'train_budget',key.train_budget,'train_used',numel(tr),'validation_used',numel(val), ...
    'seed',key.seed,'layers',string(mat2str(key.layers)),'lambda',key.lambda,'feature_count',sum(key.columns), ...
    'validation_normalized_mse',Inf,'iterations',NaN,'trainable_parameter_count',NaN,'elapsed_s',NaN, ...
    'status',"failed",'error_identifier',"",'error_message',"");
kind='ridge';if neural,kind='nn';end
cp=struct('key',key,'status','failed','kind',kind,'model',[],'selection',row);
started=tic;
try
    widths=[size(X,2) key.layers 3];row.trainable_parameter_count=sum((widths(1:end-1)+1).*widths(2:end));
    if neural
        rng(key.seed,'twister');model=fitrnet(X(tr,:),Y(tr,:),'LayerSizes',key.layers,'Activations','tanh','Standardize',true, ...
            'Lambda',key.lambda,'Verbose',0,'IterationLimit',spec.iterations,'ValidationData',{X(val,:),Y(val,:)},'ValidationPatience',spec.patience);
        raw=predict(model,X(val,:));row.iterations=model.ConvergenceInfo.Iterations;
    else,model=psf_ridge('fit',X(tr,:),Y(tr,:),key.lambda);raw=psf_ridge('predict',model,X(val,:));end
    p=min(max(raw.*spec.scale+offset(val,:),cfg.ident.bounds(:,1).'),cfg.ident.bounds(:,2).');
    loss=mean(((p-truth(val,:))./spec.scale).^2,'all');assert(isfinite(loss),'psf:Fit','Nonfinite validation loss.');
    row.validation_normalized_mse=loss;row.status="complete";cp.status='complete';cp.model=model;
catch err,row.error_identifier=string(err.identifier);row.error_message=string(err.message);end
row.elapsed_s=toc(started);cp.selection=row;
end
function write_lock(path,models)
lock=struct('key',models.key,'selection',models.selection,'test_used_for_selection',false,'evaluation_loaded',false, ...
    'ensemble_rule','Equal average of every prespecified seed; common clipping applied per seed before ensemble.');
if isfile(path),S=load(path,'lock');assert(isequaln(S.lock,lock),'psf:ResumeMismatch','Selection lock changed.');
else,pgar_model_atomic_save(path,struct('lock',lock));end
end
function write_selected(run_dir,models)
rows=struct([]);spec=models.spec;
for b=1:numel(spec.train_sizes)
    for m=1:5
        ns=1;if m<=2||m==5,ns=numel(spec.network_seeds);end
        for s=1:ns
            original=m==5;
            if original,learner=models.reference{b,s};else,learner=models.students{b,m,s};end
            r=learner.selection;layers=sscanf(char(erase(string(r.layers),["[","]"])), '%d').';
            input_dim=48;if m==2,input_dim=40;elseif m>=4,input_dim=13;end
            features=sum(learner.columns);widths=[features layers 3];parameters=sum((widths(1:end-1)+1).*widths(2:end));
            elapsed=NaN;total=NaN;candidate_count=NaN;
            if ~original
                elapsed=r.elapsed_s;mask=models.selection.method==string(r.method)&models.selection.train_budget==r.train_budget&models.selection.seed==r.seed;
                total=sum(models.selection.elapsed_s(mask));candidate_count=sum(mask);
            end
            row=struct('train_budget',r.train_budget,'method',string(r.method),'seed',r.seed,'original_frozen_reference',original, ...
                'available_input_dimensions',input_dim,'varying_input_dimensions',features,'layers',string(r.layers), ...
                'trainable_regression_parameters',parameters,'lambda',r.lambda,'validation_normalized_mse',r.validation_normalized_mse, ...
                'selected_candidate_fit_s',elapsed,'all_candidate_fit_s',total,'candidate_count',candidate_count);
            if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
        end
    end
end
writetable(struct2table(rows),fullfile(run_dir,'selected_models.csv'));
end
