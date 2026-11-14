function [bundle,report]=pca_train(runDir,I,anchor)
%PCA_TRAIN Post hoc optimizer audit on the original 12k/2k development objects.
% No test data are loaded here; the model lock is committed before evaluation.
spec=I.spec;s=I.fairSpec;folder=fullfile(runDir,'training');if ~isfolder(folder),mkdir(folder);end
modelFile=fullfile(runDir,'model_bundle.mat');
if pnn_checkpoint('exists',modelFile)
    saved=pnn_checkpoint('read',modelFile);bundle=saved.bundle;report=saved.report;
    finish_lock(runDir,modelFile,bundle,report);return
end
dataFile=fullfile(folder,'development_data.mat');
if pnn_checkpoint('exists',dataFile)
    saved=pnn_checkpoint('read',dataFile);D=saved.D;oldBundle=saved.oldBundle;
else
    [D,cfg,pnnSpec,oldBundle,sourceAudit]=psx_read_frozen(spec.training_run,Inf);
    pnn_checkpoint('write',dataFile,struct('D',D,'cfg',cfg,'pnnSpec',pnnSpec,'oldBundle',oldBundle,'sourceAudit',sourceAudit));
end
assert(strcmp(pnn_model_hash(anchor.methods(1:numel(oldBundle.methods))),pnn_model_hash(oldBundle.methods)), ...
    'pca:Anchor','Original method content differs from the matched anchor.');
assert(all(ismember(string(D.split),["train","validation"])),'pca:TestLeakage','Training received test rows.');
eligible=D.usable&all(isfinite([D.X13 D.Xaug D.base D.theta]),2);
tr=find(string(D.split)=="train"&eligible);va=find(string(D.split)=="validation"&eligible);
assert(numel(tr)==12000&&numel(va)==2000&&numel(unique(D.object_id))==14000, ...
    'pca:Data','This audit requires all 12,000 training and 2,000 validation objects.');
primary=anchor.methods(strcmp({anchor.methods.name},'ridgeSkipNN13'));skip=primary.model.skip;
X=D.X13;target=D.theta-D.base-pnn_ridge_predict(skip,X);
mu=mean(X(tr,:),1);sigma=std(X(tr,:),0,1);sigma(sigma<1e-10)=1;
amplitude=max(sqrt(mean(target(tr,:).^2,1)),s.residual_scale_floor);
% Hold the old single-rounded design/constants fixed, then optimize in double.
Z=double(single((X(tr,:)-mu)./sigma));U=[Z ones(numel(tr),1)];Y=double(single(target(tr,:)));
ampLoss=double(single(amplitude));scaleLoss=double(single(s.loss_scales));epsLoss=double(single(s.smooth_epsilon));
lambdaObjective=2*double(single(.5*s.linear_lambdas));
identity=struct('schema','pca_training_contract_v1','spec',spec,'matched_spec',s, ...
    'development_sha256',prc_file_hash(dataFile),'train_object_ids',D.object_id(tr), ...
    'validation_object_ids',D.object_id(va),'train_design_hash',pnn_model_hash({U,Y,ampLoss,scaleLoss,epsLoss}), ...
    'skip_hash',pnn_model_hash(skip),'anchor_hash',pnn_model_hash(anchor), ...
    'arithmetic','Original single-rounded design and target/constants; real-valued objective evaluated in double.', ...
    'test_rows_read',0,'posthoc_optimizer_audit',true);
contract=fullfile(folder,'TRAINING_CONTRACT.mat');
if pnn_checkpoint('exists',contract)
    prior=pnn_checkpoint('read',contract);assert(isequaln(prior.identity,identity),'pca:Identity','Training contract changed.');
else,pnn_checkpoint('write',contract,struct('identity',identity));end
checkFile=fullfile(folder,'derivative_check.mat');
if pnn_checkpoint('exists',checkFile),C=pnn_checkpoint('read',checkFile);derivativeCheck=C.report;
else
    derivativeCheck=pca_gradient_check(U,Y,ampLoss,scaleLoss,epsLoss,lambdaObjective,spec.optimizer);
    pnn_checkpoint('write',checkFile,struct('report',derivativeCheck));
end
validationBase=D.base(va,:)+pnn_ridge_predict(skip,X(va,:));
ridge=anchor.methods(strcmp({anchor.methods.name},'ridge13'));
reference=group_metrics(D.base(va,:)+pnn_ridge_predict(ridge.model,X(va,:)),D.theta(va,:),D.condition(va),s);
solutions=cell(numel(s.linear_lambdas),1);candidates=struct([]);audits=struct([]);best=[];bestKey=Inf(1,3);fixed=[];
for k=1:numel(s.linear_lambdas)
    lambda=s.linear_lambdas(k);starts=zeros(42,1);startNames={'zero'};oldAudit=struct([]);
    for seed=1:numel(s.network_seeds)
        path=fullfile(spec.matched_training,'candidates',sprintf('affine_c%02d_seed%d.mat',k,s.network_seeds(seed)));
        [source,sourceSeal]=pca_read_sealed(path,true);cp=source.checkpoint;
        assert(strcmp(cp.state.status,'complete')&&isempty(cp.identity.options.layers)&&cp.identity.options.lambda==lambda ...
            &&cp.identity.options.seed==s.network_seeds(seed)&&isequaln(cp.mu,mu)&&isequaln(cp.sigma,sigma)&&isequaln(cp.amplitude,amplitude), ...
            'pca:WarmStart','Old affine preprocessing or completion differs.');
        A=affine_parameters(cp.state.bestNet);starts(:,end+1)=A(:); %#ok<AGROW>
        startNames{end+1}=sprintf('adam_validation_best_seed%d',s.network_seeds(seed)); %#ok<AGROW>
        [f,g]=pca_objective(A(:),U,Y,ampLoss,scaleLoss,epsLoss,lambdaObjective(k));
        r=struct('seed',s.network_seeds(seed),'source_sha256',sourceSeal.sha256,'best_epoch',cp.state.bestEpoch, ...
            'stopping_reason',cp.state.stopping_reason,'objective_recomputed',f,'gradient_inf_recomputed',norm(g,inf));
        if isempty(oldAudit),oldAudit=r;else,oldAudit(end+1)=r;end %#ok<AGROW>
    end
    solveFile=fullfile(folder,sprintf('lambda_%02d.mat',k));
    if pnn_checkpoint('exists',solveFile)
        saved=pnn_checkpoint('read',solveFile);
        assert(strcmp(saved.contract_hash,pnn_model_hash(identity))&&isequaln(saved.starts,starts),'pca:Resume','Solver inputs changed.');
        trials=saved.trials;
    else
        trials=cell(size(starts,2),1);
        for j=1:size(starts,2)
            trials{j}=pca_solve_affine(starts(:,j),U,Y,ampLoss,scaleLoss,epsLoss,lambdaObjective(k),spec.optimizer);
            fprintf('PCA lambda %.3g start %s: converged=%d, f=%.12g, gradient=%.3g, iterations=%d\n', ...
                lambda,startNames{j},trials{j}.converged,trials{j}.objective,trials{j}.gradient_inf,trials{j}.iterations);
        end
        % Keep unsuccessful diagnostics too; a failure is never relabeled success.
        pnn_checkpoint('write',solveFile,struct('contract_hash',pnn_model_hash(identity),'starts',starts, ...
            'start_names',{startNames},'trials',{trials},'old_adam_audit',oldAudit));
    end
    assert(all(cellfun(@(x)x.converged,trials)),'pca:NotConverged','At least one training-only solve did not converge.');
    solution=trials{1};prediction0=(U*solution.coefficients.').*ampLoss;
    objectiveSpread=0;predictionSpread=0;
    for j=2:numel(trials)
        objectiveSpread=max(objectiveSpread,abs(trials{j}.objective-solution.objective));
        predictionSpread=max(predictionSpread,max(abs((U*trials{j}.coefficients.').*ampLoss-prediction0),[],'all'));
    end
    assert(objectiveSpread<=spec.optimizer.objective_agreement_tolerance*max(1,abs(solution.objective))&& ...
        predictionSpread<=spec.optimizer.prediction_agreement_tolerance,'pca:StartAgreement','Converged starts disagree.');
    member=make_member(solution.coefficients,mu,sigma,amplitude,lambda,solution);
    trainCorrection=pnn_nn_predict(member,X(tr,:));
    exportDifference=max(abs(trainCorrection-prediction0),[],'all');
    assert(exportDifference<=spec.optimizer.export_prediction_tolerance,'pca:Export','Legacy inference rounding exceeds frozen tolerance.');
    correction=pnn_nn_predict(member,X(va,:));
    for alpha=s.skip_alphas(:).'
        [row,key]=assess(validationBase+alpha*correction,D.theta(va,:),D.condition(va),s,reference,lambda,alpha,k);
        candidates=append(candidates,row);
        if lexless(key,bestKey),bestKey=key;best=make_entry(spec.method_names{2},member,skip,alpha,row);end
        if lambda==s.fixed_lambda&&alpha==s.fixed_alpha,fixed=make_entry(spec.method_names{1},member,skip,alpha,row);end
    end
    r=struct('lambda',lambda,'objective_lambda_after_rounding',lambdaObjective(k),'objective',solution.objective, ...
        'gradient_inf',solution.gradient_inf,'scaled_gradient_inf',solution.scaled_gradient_inf, ...
        'scaled_linear_solve_relative_residual',solution.scaled_linear_solve_relative_residual, ...
        'scaled_hessian_rcond',solution.scaled_hessian_rcond, ...
        'iterations_zero_start',solution.iterations,'starts',numel(trials), ...
        'objective_spread',objectiveSpread,'prediction_spread_physical',predictionSpread, ...
        'single_inference_export_difference_physical',exportDifference, ...
        'old_adam_best_objective_min',min([oldAudit.objective_recomputed]), ...
        'old_adam_best_objective_max',max([oldAudit.objective_recomputed]), ...
        'training_rows',numel(tr),'validation_rows',numel(va),'parameters',42,'bias_penalized',false);
    audits=append(audits,r);solutions{k}=solution;
    prc_write_json(fullfile(runDir,'progress.json'),struct('phase','training','lambda_complete',k, ...
        'lambda_total',numel(s.linear_lambdas),'updated_utc',pnn_utc(),'test_rows_read',0));
end
assert(~isempty(fixed)&&~isempty(best),'pca:Selection','Missing fixed/selected method.');
bundle=anchor;bundle.methods=[anchor.methods fixed best];
bundle.optimizer_audit=struct('schema','pca_posthoc_convex_audit_v1','source_primary',anchor.primary_method, ...
    'selection_uses_test',false,'new_confirmation',false,'training_contract_hash',pnn_model_hash(identity), ...
    'member_count',1,'ensemble_rule','One deterministic convex solution; starts are numerical checks, not seeds or samples.', ...
    'scope','Post hoc optimizer sensitivity on previously inspected test panels; frozen old methods are unchanged.');
report=struct('schema','pca_training_report_v1','completed_utc',pnn_utc(),'derivative_check',derivativeCheck, ...
    'solutions',audits,'fixed_selection',fixed.selection,'selected_selection',best.selection, ...
    'train_objects',numel(tr),'validation_objects',numel(va),'test_rows_read',0,'new_confirmation',false, ...
    'caveat','Old Adam models are validation-selected early-stopped models; training nonstationarity is not an optimizer malfunction.');
writetable(struct2table(candidates),fullfile(folder,'validation_candidates.csv'));
writetable(struct2table(audits),fullfile(folder,'convergence_summary.csv'));
prc_write_json(fullfile(folder,'TRAINING_REPORT.json'),report);
pnn_checkpoint('write',modelFile,struct('bundle',bundle,'report',report,'solutions',{solutions}));
finish_lock(runDir,modelFile,bundle,report);
end

function A=affine_parameters(net)
L=net.Learnables;iw=find(strcmp(L.Parameter,'Weights'));ib=find(strcmp(L.Parameter,'Bias'));
assert(isscalar(iw)&&isscalar(ib),'pca:Affine','Warm-start network is not one affine output.');
W=double(extractdata(L.Value{iw}));b=double(extractdata(L.Value{ib}));
assert(isequal(size(W),[3 13])&&numel(b)==3,'pca:Affine','Expected 42 parameters.');A=[W b(:)];
end
function member=make_member(A,mu,sigma,amplitude,lambda,solution)
out=fullyConnectedLayer(3,'Name','correction');out.Weights=single(A(:,1:13));out.Bias=single(A(:,14));
net=dlnetwork([featureInputLayer(13,'Normalization','none','Name','input');out]);
member=struct('schema','pnn_nn_v1','net',net,'mu',mu,'sigma',sigma,'amplitude',amplitude, ...
    'options',struct('layers',[],'lambda',lambda),'parameter_count',42,'coefficients_double',A, ...
    'optimizer','deterministic full-batch damped Newton','training_objective',solution.objective);
end
function e=make_entry(name,member,skip,alpha,selection)
m=struct('members',{{member}},'member_info',{{struct('complete',true,'deterministic',true)}},'skip',skip,'alpha',alpha);
e=struct('name',name,'kind','NN','input','X13','model',m,'selection',selection);
end
function [row,key]=assess(P,T,C,s,reference,lambda,alpha,k)
me=group_metrics(P,T,C,s);ratios=zeros(1,2*numel(me.groups));
for j=1:numel(me.groups)
    a=me.groups(j);b=reference.groups(strcmp({reference.groups.condition},a.condition));
    ratios(2*j-1:2*j)=[a.mass/max(b.mass,1e-12),a.com/max(b.com,1e-12)];
end
row=struct('candidate_id',sprintf('convex_c%02d_a%.17g',k,alpha),'lambda',lambda,'alpha',alpha, ...
    'physical_score',me.score,'worst_ratio',max(ratios),'mean_ratio',mean(ratios), ...
    'parameters',42,'member_count',1,'selection_uses_test',false);key=[row.worst_ratio row.mean_ratio row.physical_score];
end
function m=group_metrics(P,T,C,s)
E=P-T;assert(all(isfinite(E),'all'),'pca:Validation','Nonfinite validation prediction.');
m.score=mean((abs(E(:,1))/s.loss_scales(1)+sqrt(sum(E(:,2:3).^2,2))/s.loss_scales(2))/2);
conditions=unique(string(C),'stable');m.groups=struct('condition',{},'mass',{},'com',{});
for j=1:numel(conditions)
    ix=string(C)==conditions(j);m.groups(j)=struct('condition',char(conditions(j)), ...
        'mass',1000*mean(abs(E(ix,1))),'com',1000*mean(sqrt(sum(E(ix,2:3).^2,2))));
end
end
function yes=lexless(a,b)
yes=false;for j=1:numel(a),if a(j)<b(j),yes=true;return;elseif a(j)>b(j),return;end,end
end
function out=append(out,row),if isempty(out),out=row;else,out(end+1)=row;end,end
function finish_lock(runDir,path,bundle,report)
lock=struct('schema','pca_model_lock_v1','bundle_sha256',prc_file_hash(path), ...
    'bundle_content_hash',pnn_model_hash(bundle),'fixed_selection',report.fixed_selection, ...
    'selected_selection',report.selected_selection,'selection_uses_test',false,'new_confirmation',false);
file=fullfile(runDir,'MODEL_LOCK.json');
if isfile(file),old=jsondecode(fileread(file));assert(strcmp(old.bundle_sha256,lock.bundle_sha256)&&strcmp(old.bundle_content_hash,lock.bundle_content_hash));
else,prc_write_json(file,lock);end
end
