function [info,bundle]=pnn_train(D,spec,outdir)
%PNN_TRAIN Locked offline comparison. Test rows/labels are forbidden here.
% Hyperparameters are common across all three seeds; no seed is selected.
% Ridge13 minimizes the physical mean. Other model candidates minimize the
% worst condition/target MAE ratio to ridge13, then the mean ratio. Epoch
% stopping uses the smooth physical mean, not this groupwise minimax score.
spec=defaults(spec);outdir=char(outdir);if ~isfolder(outdir),mkdir(outdir);end
validate_data(D);split=string(D.split(:));train=split=="train";val=split=="validation";
assert(~any(split=="test")&&all(train|val),'pnn:TestLeakage','Only train and validation rows are permitted.');
assert(isempty(intersect(D.object_id(train),D.object_id(val))),'pnn:SplitLeakage','Object overlaps train/validation.');
eligible=logical(D.usable(:))&all(isfinite([D.X13 D.Xaug D.base D.theta]),2);
tr=find(train&eligible);va=find(val&eligible);
assert(numel(tr)>=4&&numel(va)>=2,'pnn:Data','Insufficient common eligible data.');
assert(all(ismember(unique(string(D.condition(train))),unique(string(D.condition(va))))), ...
    'pnn:ConditionCoverage','Validation must represent every training condition.');
for c=reshape(string(spec.required_conditions),1,[])
    assert(sum(string(D.condition(tr))==c)>=spec.min_eligible_per_condition&& ...
        sum(string(D.condition(va))==c)>=spec.min_eligible_per_condition, ...
        'pnn:ConditionCoverage','A prespecified condition lacks eligible train/validation examples.');
end
contract=struct('schema','pnn_training_contract_v1','spec',spec,'data_hash',pnn_model_hash(D), ...
    'train_ids',D.object_id(tr),'validation_ids',D.object_id(va),'source_hashes',source_hashes(), ...
    'release',version('-release'),'eligibility','usable and finite X13/Xaug/base/theta; rejected teachers retained');
contractHash=pnn_model_hash(contract);contractPath=fullfile(outdir,'TRAINING_CONTRACT.mat');
if pnn_model_exists(contractPath)
    old=pnn_model_load(contractPath);assert(isequaln(old.contract,contract),'pnn:ResumeMismatch','Training contract changed.');
else,pnn_model_atomic_save(contractPath,struct('contract',contract));end
modelpath=fullfile(outdir,'model_bundle.mat');
if pnn_model_exists(modelpath)
    [old,bundleAudit]=pnn_model_load(modelpath);bundle=old.bundle;
    assert(strcmp(bundle.contract_hash,contractHash),'pnn:ResumeMismatch','Existing bundle belongs to another contract.');
    lockpath=fullfile(outdir,'LOCKED_SELECTION_BEFORE_TEST.mat');
    if ~bundleAudit.mirror_matches
        assert(~isfile(fullfile(outdir,'MODEL_LOCK.json'))&&~isfile(lockpath)&& ...
            ~isfolder([lockpath '.generations']),'pnn:LockedModelChanged','Locked bundle mirror changed.');
        % Only the pre-lock crash window may restore a mirror. Preserve any
        % damaged mirror, then copy the already sealed complete generation.
        if isfile(modelpath),movefile(modelpath,[modelpath '.corrupt_' char(javaMethod('randomUUID','java.util.UUID'))]);end
        temporary=[tempname(outdir) '.mat'];copyfile(bundleAudit.generation,temporary);movefile(temporary,modelpath);
        assert(strcmp(pnn_model_hash(modelpath,'file'),bundleAudit.sha256),'pnn:Recovery','Bundle mirror restore failed.');
    end
    if pnn_model_exists(lockpath)
        [oldLock,lockAudit]=pnn_model_load(lockpath);lock=oldLock.lock;
        assert(isscalar(lock)&&strcmp(lock.bundle_sha256,pnn_model_hash(modelpath,'file'))&& ...
            strcmp(lock.contract_hash,contractHash),'pnn:Lock','Existing bundle/lock mismatch.');
        if ~lockAudit.mirror_matches
            assert(~isfile(fullfile(outdir,'MODEL_LOCK.json')),'pnn:LockedModelChanged','Locked selection mirror changed.');
            if isfile(lockpath),movefile(lockpath,[lockpath '.corrupt_' char(javaMethod('randomUUID','java.util.UUID'))]);end
            temporary=[tempname(outdir) '.mat'];copyfile(lockAudit.generation,temporary);movefile(temporary,lockpath);
            assert(strcmp(pnn_model_hash(lockpath,'file'),lockAudit.sha256),'pnn:Recovery','Selection mirror restore failed.');
        end
    else
        % A crash between the two atomic writes is recoverable from the
        % already complete bundle; no training or selection is rerun here.
        lock=make_lock(bundle,modelpath);pnn_model_atomic_save(lockpath,struct('lock',lock));
    end
    info=struct('complete',true,'modelpath',modelpath,'contract_hash',contractHash,'model_sha256',lock.bundle_sha256);return
end
candidateDir=fullfile(outdir,'candidates');if ~isfolder(candidateDir),mkdir(candidateDir);end
coverage=table(["train";"validation"],[sum(train);sum(val)],[numel(tr);numel(va)], ...
    [sum(train&logical(D.accepted(:)));sum(val&logical(D.accepted(:)))], ...
    'VariableNames',{'split','planned','common_eligible','teacher_accepted'});
writetable(coverage,fullfile(outdir,'training_coverage.csv'));
T=D.theta;Y=T-D.base;C=string(D.condition(va));methods=struct('name',{},'kind',{},'input',{},'model',{},'selection',{});
rows=struct([]);conditionRows=struct([]);reference=[];
for r=1:3
    names={'ridge13','ridgeAug','interactionRidge'};name=names{r};
    if r==1,X=D.X13;input='X13';else,X=D.Xaug;input='Xaug';end
    if r==3,mode='interaction';else,mode='linear';end
    bestKey=[Inf Inf Inf];chosen=[];chosenRow=[];
    for k=1:numel(spec.ridge_lambdas)
        lambda=spec.ridge_lambdas(k);id=sprintf('%s_l%02d',name,k);
        path=fullfile(candidateDir,[id '.mat']);key=struct('contract',contractHash,'id',id);
        if pnn_model_exists(path)
            old=pnn_model_load(path);assert(isequaln(old.saved.key,key),'pnn:ResumeMismatch','Ridge identity changed.');model=old.saved.model;
        else
            model=pnn_ridge_fit(X(tr,:),Y(tr,:),lambda,mode);
            saved=struct('key',key,'model',model);pnn_model_atomic_save(path,struct('saved',saved));
        end
        P=D.base(va,:)+pnn_ridge_predict(model,X(va,:));
        [row,cr,metrics]=selection_row(id,name,lambda,'linear',1,P,T(va,:),C,spec,reference);
        row.feature_count=model.feature_count;row.seed_count=1;rows=append(rows,row);conditionRows=append(conditionRows,cr);
        if r==1,candidateKey=[row.physical_score 0 0];else,candidateKey=[row.worst_ratio row.mean_ratio row.physical_score];end
        if lexless(candidateKey,bestKey),bestKey=candidateKey;chosen=model;chosenRow=row;chosenMetrics=metrics;end
    end
    methods(end+1)=entry(name,'ridge',input,chosen,chosenRow); %#ok<AGROW>
    if r==1,reference=chosenMetrics;end
    write_selection(outdir,rows,conditionRows);progress(outdir,name,numel(rows));
end
% Original settings are retained as an anchor, including the old MSE and
% output range scales. fitrnet has only completed-seed restart granularity.
name='oldNN13';members=cell(1,numel(spec.network_seeds));memberInfo=cell(size(members));
for s=1:numel(spec.network_seeds)
    path=fullfile(candidateDir,sprintf('%s_seed%d.mat',name,spec.network_seeds(s)));
    key=struct('contract',contractHash,'seed',spec.network_seeds(s),'method',name);
    if pnn_model_exists(path)
        old=pnn_model_load(path);assert(isequaln(old.saved.key,key),'pnn:ResumeMismatch','Anchor identity changed.');
        members{s}=old.saved.model;memberInfo{s}=old.saved.info;
    else
        caller=rng;rng(spec.network_seeds(s),'twister');
        try
            model=fitrnet(D.X13(tr,:),Y(tr,:)./spec.old_scale,'LayerSizes',spec.old_layers, ...
                'Activations','tanh','Standardize',true,'StandardizeResponses',false, ...
                'Lambda',spec.old_lambda,'IterationLimit',spec.old_iterations, ...
                'ValidationData',{D.X13(va,:),Y(va,:)./spec.old_scale},'ValidationPatience',spec.old_patience);
        catch err,rng(caller);rethrow(err);end
        rng(caller);ci=model.ConvergenceInfo;
        details=struct('iterations',ci.Iterations,'criterion',char(ci.ConvergenceCriterion), ...
            'history',ci.History,'restart_scope','Completed seed; an interrupted fitrnet seed is deterministically refit.');
        saved=struct('key',key,'model',model,'info',details);pnn_model_atomic_save(path,struct('saved',saved));
        members{s}=model;memberInfo{s}=details;
    end
end
P=zeros(numel(va),3,numel(members));
for s=1:numel(members),P(:,:,s)=double(predict(members{s},D.X13(va,:))).*spec.old_scale+D.base(va,:);end
[row,cr]=selection_row(name,name,spec.old_lambda,mat2str(spec.old_layers),1,mean(P,3),T(va,:),C,spec,reference);
row.feature_count=13;rows=append(rows,row);conditionRows=append(conditionRows,cr);
methods(end+1)=entry(name,'oldNN','X13',struct('members',{members},'member_info',{memberInfo},'scale',spec.old_scale),row);
write_selection(outdir,rows,conditionRows);progress(outdir,name,numel(rows));
newNames={'scaledNN13','ridgeSkipNN13','ridgeSkipNNaug'};
for m=1:numel(newNames)
    name=newNames{m};
    if m==3,X=D.Xaug;input='Xaug';skip=methods(2).model;else,X=D.X13;input='X13';skip=[];end
    if m==2,skip=methods(1).model;end
    target=Y;
    if ~isempty(skip),target=target-pnn_ridge_predict(skip,X);end
    bestKey=[Inf Inf Inf];chosen=[];chosenRow=[];
    for l=1:numel(spec.nn_layers)
        for w=1:numel(spec.nn_lambdas)
            members=cell(1,numel(spec.network_seeds));memberInfo=cell(size(members));P=zeros(numel(va),3,numel(members));
            for s=1:numel(members)
                o=nn_options(spec);o.layers=spec.nn_layers{l};o.lambda=spec.nn_lambdas(w);o.seed=spec.network_seeds(s);
                path=fullfile(candidateDir,sprintf('%s_l%02d_w%02d_seed%d.mat',name,l,w,o.seed));
                [members{s},memberInfo{s}]=pnn_nn_fit(X(tr,:),target(tr,:),X(va,:),target(va,:),o,path);
                assert(memberInfo{s}.complete,'pnn:Paused','Candidate paused before completion.');
                P(:,:,s)=pnn_nn_predict(members{s},X(va,:));
                progress(outdir,sprintf('%s_l%d_w%d_seed%d',name,l,w,s),numel(rows));
            end
            alphas=1;if ~isempty(skip),alphas=spec.skip_alphas;end
            base=D.base(va,:);if ~isempty(skip),base=base+pnn_ridge_predict(skip,X(va,:));end
            for alpha=alphas
                id=sprintf('%s_l%02d_w%02d_a%.2f',name,l,w,alpha);
                [row,cr]=selection_row(id,name,spec.nn_lambdas(w),mat2str(spec.nn_layers{l}),alpha, ...
                    base+alpha*mean(P,3),T(va,:),C,spec,reference);
                row.feature_count=size(X,2);rows=append(rows,row);conditionRows=append(conditionRows,cr);
                candidateKey=[row.worst_ratio row.mean_ratio row.physical_score];
                if lexless(candidateKey,bestKey)
                    bestKey=candidateKey;chosenRow=row;
                    chosen=struct('members',{members},'member_info',{memberInfo},'skip',skip,'alpha',alpha);
                end
            end
            write_selection(outdir,rows,conditionRows);
        end
    end
    methods(end+1)=entry(name,'NN',input,chosen,chosenRow); %#ok<AGROW>
end
methods(end+1)=entry('physics6','physics6','',[],struct());
methods(end+1)=entry('physics8','physics8','',[],struct());
selectedRows=[methods(1:7).selection];writetable(struct2table(selectedRows),fullfile(outdir,'selected_models.csv'));
primary='';primaryKey=[Inf Inf];
for k=1:numel(newNames)
    ix=find(strcmp({methods.name},newNames{k}));r=methods(ix).selection;
    key=[r.worst_ratio r.mean_ratio];
    if lexless(key,primaryKey),primary=newNames{k};primaryKey=key;end
end
bundle=struct('schema','pnn_bundle_v1','methods',methods,'spec',spec,'contract_hash',contractHash, ...
    'training_object_ids',D.object_id(tr),'validation_object_ids',D.object_id(va), ...
    'test_used_for_selection',false,'selection_uses_test',false,'bounds',spec.bounds,'primary_method',primary, ...
    'selection_rule','Ridge13 physical mean; others condition/target worst ratio then mean ratio to ridge13.', ...
    'ensemble_rule','Equal average of every prespecified seed in physical units, before any common clipping.', ...
    'epoch_selection','Smooth physical mean, including the zero-correction epoch0; not groupwise minimax.', ...
    'feature_schema','X13 and augmented deployable features; no unknown truth in prediction');
pnn_model_atomic_save(modelpath,struct('bundle',bundle));
lock=make_lock(bundle,modelpath);
pnn_model_atomic_save(fullfile(outdir,'LOCKED_SELECTION_BEFORE_TEST.mat'),struct('lock',lock));
info=struct('complete',true,'modelpath',modelpath,'contract_hash',contractHash,'model_sha256',lock.bundle_sha256);
progress(outdir,'complete',numel(rows));
end

function lock=make_lock(bundle,modelpath)
selection={bundle.methods.selection};
lock=struct('schema','pnn_selection_lock_v1','created_at',char(datetime('now','TimeZone','UTC')), ...
    'bundle_path',modelpath,'bundle_sha256',pnn_model_hash(modelpath,'file'), ...
    'contract_hash',bundle.contract_hash,'selection_uses_test',false, ...
    'primary_method',bundle.primary_method,'selection',{selection});
end

function e=entry(name,kind,input,model,selection)
e=struct('name',name,'kind',kind,'input',input,'model',model,'selection',selection);
end
function [row,cr,metrics]=selection_row(id,name,lambda,layers,alpha,P,T,C,spec,reference)
conditions=unique(C,'stable');cr=struct([]);metrics=struct('condition',{},'mass',{},'com',{});
E=P-T;score=mean((abs(E(:,1))/spec.loss_scales(1)+sqrt(sum(E(:,2:3).^2,2))/spec.loss_scales(2))/2);
ratios=[];
for k=1:numel(conditions)
    ix=C==conditions(k);mass=mean(abs(E(ix,1)))*1000;com=mean(sqrt(sum(E(ix,2:3).^2,2)))*1000;
    metrics(k)=struct('condition',char(conditions(k)),'mass',mass,'com',com);
    massRatio=NaN;comRatio=NaN;
    if ~isempty(reference)
        ref=reference(strcmp({reference.condition},char(conditions(k))));assert(isscalar(ref),'pnn:Selection','Reference condition absent.');
        massRatio=mass/max(ref.mass,1e-12);comRatio=com/max(ref.com,1e-12);ratios=[ratios massRatio comRatio]; %#ok<AGROW>
    end
    cr=append(cr,struct('candidate_id',id,'method',name,'condition',char(conditions(k)), ...
        'n',sum(ix),'mass_MAE_g',mass,'com_MAE_mm',com,'mass_ratio',massRatio,'com_ratio',comRatio));
end
worst=NaN;average=NaN;if ~isempty(ratios),worst=max(ratios);average=mean(ratios);end
row=struct('candidate_id',id,'method',name,'lambda',lambda,'layers',layers,'alpha',alpha, ...
    'feature_count',NaN,'seed_count',numel(spec.network_seeds),'physical_score',score, ...
    'worst_ratio',worst,'mean_ratio',average,'status','complete');
end
function yes=lexless(a,b)
yes=false;for k=1:numel(a),if a(k)<b(k),yes=true;return;elseif a(k)>b(k),return;end,end
end
function rows=append(rows,new)
if isempty(rows),rows=new;else,rows=[rows new];end
end
function write_selection(outdir,rows,conditionRows)
writetable(struct2table(rows),fullfile(outdir,'validation_candidates.csv'));
writetable(struct2table(conditionRows),fullfile(outdir,'validation_condition_metrics.csv'));
end
function progress(outdir,stage,n)
p=struct('stage',stage,'selection_rows',n,'updated_at',char(datetime('now','TimeZone','UTC')));
path=fullfile(outdir,'training_progress.json');temporary=[path '.tmp'];
fid=fopen(temporary,'w');assert(fid>=0,'pnn:Progress','Cannot write progress.');
fwrite(fid,jsonencode(p),'char');fclose(fid);movefile(temporary,path,'f');
end
function validate_data(D)
fields={'X13','Xaug','base','physics8','theta','usable','accepted','physics8accepted','object_id','trial_id','split','condition'};
assert(all(isfield(D,fields)),'pnn:Data','Dataset fields missing.');N=size(D.theta,1);
for k=1:numel(fields),assert(size(D.(fields{k}),1)==N,'pnn:Data','Row count mismatch.');end
assert(size(D.X13,2)==13&&size(D.Xaug,2)>=13&&size(D.Xaug,2)<=64&& ...
    size(D.base,2)==3&&size(D.theta,2)==3,'pnn:Data','Feature or target dimensions invalid.');
assert(numel(unique(D.trial_id))==N,'pnn:Data','Duplicate trial ID.');
assert(isequaln(D.Xaug(:,1:13),D.X13),'pnn:Data','First augmented features must exactly equal X13.');
end
function hashes=source_hashes()
names={'pnn_train','pnn_predict','pnn_nn_fit','pnn_nn_predict','pnn_ridge_fit', ...
    'pnn_ridge_predict','pnn_model_atomic_save','pnn_model_hash','pnn_model_load','pnn_model_exists','pnn_checkpoint','prc_file_hash'};hashes=struct('name',{},'sha256',{});
for k=1:numel(names),hashes(k)=struct('name',names{k},'sha256',pnn_model_hash(which(names{k}),'file'));end
end
function o=nn_options(s)
fields={'max_epochs','patience','checkpoint_every','batch_size','learn_rate','adam_beta1', ...
    'adam_beta2','adam_epsilon','smooth_epsilon','loss_scales','residual_scale_floor'};
o=struct();for k=1:numel(fields),o.(fields{k})=s.(fields{k});end
end
function s=defaults(s)
d=struct('network_seeds',[1430101 1430102 1430103],'nn_layers',{{16,[32 16]}}, ...
    'nn_lambdas',[1e-6 1e-4 1e-2],'ridge_lambdas',10.^(-7:0),'max_epochs',1500, ...
    'patience',150,'checkpoint_every',5,'batch_size',256,'learn_rate',.001, ...
    'adam_beta1',.9,'adam_beta2',.999,'adam_epsilon',1e-8,'smooth_epsilon',.1, ...
    'loss_scales',[.001 .001 .001],'residual_scale_floor',[1e-5 1e-5 1e-5], ...
    'bounds',[.06 .25;.04 .20;-.025 .025],'old_scale',[.14 .14 .036], ...
    'old_layers',8,'old_lambda',.001,'old_iterations',800,'old_patience',30, ...
    'skip_alphas',[0 .25 .5 .75 1],'required_conditions',{{'nominal','mechanical','electrical','combined'}}, ...
    'min_eligible_per_condition',2);
f=fieldnames(d);for k=1:numel(f),if ~isfield(s,f{k}),s.(f{k})=d.(f{k});end,end
assert(numel(s.network_seeds)>=1&&numel(unique(s.network_seeds))==numel(s.network_seeds)&& ...
    all(s.ridge_lambdas>0)&&all(s.nn_lambdas>=0)&&all(s.skip_alphas>=0&s.skip_alphas<=1), ...
    'pnn:Spec','Invalid seed or candidate grid.');
end
