function [info,bundle]=pfl_train(D,anchor,spec,outdir)
%PFL_TRAIN Fair affine correction mechanism ablation with sealed checkpoints.
% No test row is accepted. Every supplied seed is equally averaged; seeds
% are optimization replicates, not independent statistical observations.
% layers=[] in pnn_nn_fit creates input->affine(3), including a bias, with
% the exact same train-only scales, smooth physical loss, and Adam routine.
outdir=char(outdir);bundle=[];
assert(~strcmp(spec.mode,'futurefull')||spec.full_run_authorized, ...
    'pfl:FullNotAuthorized','Full training requires a later explicit user instruction and full_run_authorized=true.');
[tr,va]=validate(D,anchor,spec);
assert(~isfile(fullfile(outdir,'LOCKED_BEFORE_GENERATION.json'))&& ...
    ~isfile(fullfile(outdir,'FROZEN_PROTOCOL.txt'))&&~isfile(fullfile(outdir,'data_plan.mat')), ...
    'pfl:Destination','Existing generation/frozen run directories are read-only.');
if ~isfolder(outdir),mkdir(outdir);end
f=javaObject('java.io.RandomAccessFile',fullfile(outdir,'pfl_training.lock'),'rw');ch=f.getChannel();
try,lk=ch.tryLock();catch err,ch.close();f.close();rethrow(err);end
if isempty(lk),ch.close();f.close();error('pfl:Busy','Another process owns this ablation.');end
clean=onCleanup(@()release(lk,ch,f)); %#ok<NASGU>
primary=anchor.methods(strcmp({anchor.methods.name},anchor.primary_method));
ridge=anchor.methods(strcmp({anchor.methods.name},'ridge13'));
assert(isscalar(ridge),'pfl:Anchor','Frozen ridge13 reference required.');
idSpec=rmfield(spec,'stop_after_epoch');
anchorKey=struct('contract_hash',anchor.contract_hash,'primary_method',anchor.primary_method, ...
    'primary_selection',primary.selection,'skip',primary.model.skip,'ridge13',ridge.model);
contract=struct('schema','pfl_training_contract_v1','spec',idSpec, ...
    'data_hash',pnn_model_hash(D),'anchor_hash',pnn_model_hash(anchorKey), ...
    'train_object_ids',D.object_id(tr),'validation_object_ids',D.object_id(va), ...
    'source_hashes',sources(),'release',version('-release'), ...
    'selection_uses_test',false,'future_independent_test_required',true);
contractHash=pnn_model_hash(contract);cp=fullfile(outdir,'TRAINING_CONTRACT.mat');
if pnn_model_exists(cp)
    old=pnn_model_load(cp);assert(isequaln(old.contract,contract),'pfl:ResumeMismatch','Ablation contract changed.');
else,pnn_model_atomic_save(cp,struct('contract',contract));end
modelpath=fullfile(outdir,'model_bundle.mat');
if pnn_model_exists(modelpath)
    [old,audit]=pnn_model_load(modelpath);bundle=old.bundle;
    assert(strcmp(bundle.contract_hash,contractHash),'pfl:ResumeMismatch','Bundle belongs to another contract.');
    restore_mirror(modelpath,audit);
    finish_lock(bundle,modelpath,outdir);
    info=make_info(true,'complete',contractHash,modelpath);return
end
X=D.(spec.input);skip=primary.model.skip;
target=D.theta-D.base-pnn_ridge_predict(skip,X);
validationBase=D.base(va,:)+pnn_ridge_predict(skip,X(va,:));
refP=D.base(va,:)+pnn_ridge_predict(ridge.model,D.X13(va,:));
reference=metrics(refP,D.theta(va,:),string(D.condition(va)),spec);
coverage=table(["train";"validation"],[sum(string(D.split)=="train");sum(string(D.split)=="validation")], ...
    [numel(tr);numel(va)],[sum(D.accepted(tr));sum(D.accepted(va))], ...
    'VariableNames',{'split','planned_objects','common_eligible_objects','teacher_accepted_objects'});
writetable(coverage,fullfile(outdir,'training_coverage.csv'));
grid=struct('family',{},'index',{},'layers',{},'lambda',{});
for i=1:numel(spec.linear_lambdas)
    grid(end+1)=struct('family','affine','index',i,'layers',[],'lambda',spec.linear_lambdas(i)); %#ok<AGROW>
end
n=0;for i=1:numel(spec.nn_layers),for j=1:numel(spec.nn_lambdas)
    n=n+1;grid(end+1)=struct('family','nonlinear','index',n,'layers',spec.nn_layers{i},'lambda',spec.nn_lambdas(j)); %#ok<AGROW>
end,end
candDir=fullfile(outdir,'candidates');if ~isfolder(candDir),mkdir(candDir);end
families={'affine','nonlinear'};bestKey={Inf(1,3),Inf(1,3)};best=cell(1,2);fixed=cell(1,2);
rows=struct([]);conditionRows=struct([]);fixedRows=struct([]);fixedConditionRows=struct([]);
for g=1:numel(grid)
    c=grid(g);family=find(strcmp(families,c.family));members=cell(1,numel(spec.network_seeds));
    memberInfo=cell(size(members));P=zeros(numel(va),3,numel(members));
    for seed=1:numel(members)
        opt=options(spec);opt.seed=spec.network_seeds(seed);opt.layers=c.layers;opt.lambda=c.lambda;
        file=fullfile(candDir,sprintf('%s_c%02d_seed%d.mat',c.family,c.index,opt.seed));
        [members{seed},memberInfo{seed}]=pnn_nn_fit(X(tr,:),target(tr,:),X(va,:),target(va,:),opt,file);
        progress(outdir,c.family,c.index,seed,memberInfo{seed}.epoch,memberInfo{seed}.status);
        if ~memberInfo{seed}.complete
            info=make_info(false,'paused',contractHash,modelpath);return
        end
        P(:,:,seed)=pnn_nn_predict(members{seed},X(va,:));
    end
    meanP=mean(P,3);
    for alpha=spec.skip_alphas(:).'
        [row,cr,key]=assess(c,alpha,validationBase+alpha*meanP,D.theta(va,:), ...
            string(D.condition(va)),spec,reference,members,'selected_grid');
        rows=append(rows,row);conditionRows=append(conditionRows,cr);
        if lexless(key,bestKey{family})
            bestKey{family}=key;best{family}=entry([c.family '_selected'],spec.input, ...
                model(members,memberInfo,skip,alpha),row);
        end
    end
    isFixed=c.lambda==spec.fixed_lambda&&(strcmp(c.family,'affine')||isequal(c.layers,spec.fixed_layers));
    if isFixed
        assert(isempty(fixed{family}),'pfl:Grid','Duplicate fixed pair candidate.');
        [row,cr]=assess(c,spec.fixed_alpha,validationBase+spec.fixed_alpha*meanP,D.theta(va,:), ...
            string(D.condition(va)),spec,reference,members,'fixed_frozen_hyperparameters');
        fixed{family}=entry([c.family '_fixed'],spec.input,model(members,memberInfo,skip,spec.fixed_alpha),row);
        fixedRows=append(fixedRows,row);fixedConditionRows=append(fixedConditionRows,cr);
    end
    writetable(struct2table(rows),fullfile(outdir,'validation_candidates.csv'));
    writetable(struct2table(conditionRows),fullfile(outdir,'validation_condition_metrics.csv'));
end
assert(all(~cellfun(@isempty,best))&&all(~cellfun(@isempty,fixed)),'pfl:Grid','Missing selected model or fixed pair.');
methods=struct('name','ridge_anchor','kind','ridge','input',spec.input,'model',skip,'selection',struct());
methods=[methods best{1} best{2} fixed{1} fixed{2}];
writetable(struct2table([best{1}.selection best{2}.selection]),fullfile(outdir,'selected_models.csv'));
writetable(struct2table(fixedRows),fullfile(outdir,'fixed_pair_validation.csv'));
writetable(struct2table(fixedConditionRows),fullfile(outdir,'fixed_pair_validation_conditions.csv'));
budget=table(string(families).',[numel(spec.linear_lambdas);numel(spec.nn_layers)*numel(spec.nn_lambdas)], ...
    repmat(numel(spec.network_seeds),2,1),repmat(numel(spec.skip_alphas),2,1), ...
    repmat(spec.max_epochs,2,1),repmat(spec.patience,2,1), ...
    'VariableNames',{'family','training_configurations','seeds_per_configuration','alpha_values_per_configuration','max_epochs','patience'});
writetable(budget,fullfile(outdir,'search_budget.csv'));
bundle=struct('schema','pfl_bundle_v1','methods',methods,'spec',idSpec,'contract_hash',contractHash, ...
    'training_object_ids',D.object_id(tr),'validation_object_ids',D.object_id(va), ...
    'selection_uses_test',false,'test_used_for_selection',false,'bounds',spec.bounds, ...
    'primary_method','nonlinear_selected','fixed_pair',{{'affine_fixed','nonlinear_fixed'}}, ...
    'ensemble_rule','Equal physical-unit average of every prespecified seed; no seed selection.', ...
    'epoch_selection','Smooth physical mean, including zero-correction epoch 0, identical to pnn_nn_fit.', ...
    'selection_rule',spec.selection_rule,'statistical_unit',spec.statistical_unit, ...
    'search_caveat',spec.search_caveat,'fixed_pair_rule',spec.fixed_pair_rule, ...
    'source_anchor_method',anchor.primary_method,'future_independent_test_required',true, ...
    'non_scientific_smoke',spec.non_scientific_smoke);
pnn_model_atomic_save(modelpath,struct('bundle',bundle));finish_lock(bundle,modelpath,outdir);
info=make_info(true,'complete',contractHash,modelpath);progress(outdir,'complete',numel(grid),numel(spec.network_seeds),NaN,'complete');
end

function [tr,va]=validate(D,anchor,s)
required={'X13','Xaug','base','theta','usable','accepted','object_id','trial_id','split','condition'};
assert(all(isfield(D,required)),'pfl:Data','Dataset fields missing.');
N=size(D.theta,1);for i=1:numel(required),assert(size(D.(required{i}),1)==N,'pfl:Data','Row count mismatch.');end
split=string(D.split(:));assert(all(ismember(split,["train","validation"])),'pfl:TestLeakage','Only train and validation rows permitted.');
assert(numel(unique(D.trial_id))==N,'pfl:DuplicateTrial','Duplicate trial.');
assert(numel(unique(D.object_id))==N,'pfl:ObjectUnit','Exactly one train/validation episode per independent object required.');
assert(size(D.X13,2)==13&&size(D.theta,2)==3&&size(D.base,2)==3&& ...
    isequaln(D.Xaug(:,1:13),D.X13),'pfl:Data','Invalid feature schema.');
primary=anchor.methods(strcmp({anchor.methods.name},anchor.primary_method));
assert(isscalar(primary)&&ismember(s.input,{'X13','Xaug'})&&strcmp(s.anchor_method,anchor.primary_method)&& ...
    strcmp(s.input,primary.input),'pfl:Anchor','Anchor/input mismatch.');
assert(isequal(s.network_seeds(:),unique(s.network_seeds(:),'stable'))&&numel(s.network_seeds)>=1,'pfl:Spec','Invalid seeds.');
assert(numel(s.linear_lambdas)==numel(s.nn_layers)*numel(s.nn_lambdas)&& ...
    numel(unique(s.linear_lambdas))==numel(s.linear_lambdas)&&all(s.linear_lambdas>=0)&& ...
    any(s.linear_lambdas==s.fixed_lambda)&&any(s.nn_lambdas==s.fixed_lambda)&& ...
    any(cellfun(@(x)isequal(x,s.fixed_layers),s.nn_layers)),'pfl:Budget','Equal unique candidate counts and a fixed pair required.');
assert(all(s.skip_alphas>=0&s.skip_alphas<=1)&&any(s.skip_alphas==0)&& ...
    any(s.skip_alphas==s.fixed_alpha),'pfl:Spec','Alpha grid must include zero and fixed alpha.');
eligible=logical(D.usable(:))&all(isfinite([D.X13 D.Xaug D.base D.theta]),2);
tr=find(split=="train"&eligible);va=find(split=="validation"&eligible);
assert(numel(tr)>=4&&numel(va)>=2,'pfl:Data','Insufficient common eligible data.');
for c=string(s.required_conditions(:)).'
    assert(sum(string(D.condition(tr))==c)>=s.min_eligible_per_condition&& ...
        sum(string(D.condition(va))==c)>=s.min_eligible_per_condition,'pfl:ConditionCoverage','Required condition lacks eligible objects.');
end
end
function o=options(s)
fields={'max_epochs','patience','checkpoint_every','batch_size','learn_rate','adam_beta1','adam_beta2', ...
    'adam_epsilon','smooth_epsilon','loss_scales','residual_scale_floor','stop_after_epoch'};
o=struct();for k=1:numel(fields),o.(fields{k})=s.(fields{k});end
end
function m=model(members,info,skip,alpha)
m=struct('members',{members},'member_info',{info},'skip',skip,'alpha',alpha);
end
function e=entry(name,input,m,row)
e=struct('name',name,'kind','NN','input',input,'model',m,'selection',row);
end
function [r,cr,key]=assess(c,alpha,P,T,C,s,reference,members,purpose)
me=metrics(P,T,C,s);ratios=zeros(1,2*numel(me.groups));cr=struct([]);
id=sprintf('%s_c%02d_a%.17g',c.family,c.index,alpha);
for k=1:numel(me.groups)
    q=me.groups(k);r0=reference.groups(strcmp({reference.groups.condition},q.condition));
    assert(isscalar(r0),'pfl:ConditionCoverage','Reference missing condition.');
    ratios(2*k-1:2*k)=[q.mass/max(r0.mass,1e-12) q.com/max(r0.com,1e-12)];
    cr=append(cr,struct('candidate_id',id,'purpose',purpose,'family',c.family, ...
        'condition',q.condition,'n_objects',q.n,'mass_MAE_g',q.mass,'com_MAE_mm',q.com, ...
        'mass_ratio',ratios(2*k-1),'com_ratio',ratios(2*k)));
end
r=struct('candidate_id',id,'purpose',purpose,'family',c.family,'lambda',c.lambda, ...
    'layers',mat2str(c.layers),'alpha',alpha,'feature_count',numel(members{1}.mu), ...
    'seed_count',numel(members),'parameters_per_seed',members{1}.parameter_count, ...
    'physical_score',me.score,'worst_ratio',max(ratios),'mean_ratio',mean(ratios),'status','complete');
key=[r.worst_ratio r.mean_ratio r.physical_score];
end
function m=metrics(P,T,C,s)
E=P-T;assert(all(isfinite(E),'all'),'pfl:Nonfinite','Nonfinite eligible validation prediction.');
m.score=mean((abs(E(:,1))/s.loss_scales(1)+sqrt(sum(E(:,2:3).^2,2))/s.loss_scales(2))/2);
conditions=unique(C,'stable');m.groups=struct('condition',{},'n',{},'mass',{},'com',{});
for k=1:numel(conditions)
    ix=C==conditions(k);m.groups(k)=struct('condition',char(conditions(k)),'n',sum(ix), ...
        'mass',1000*mean(abs(E(ix,1))),'com',1000*mean(sqrt(sum(E(ix,2:3).^2,2))));
end
end
function yes=lexless(a,b)
yes=false;for k=1:numel(a),if a(k)<b(k),yes=true;return;elseif a(k)>b(k),return;end,end
end
function a=append(a,b),if isempty(a),a=b;else,a=[a b];end,end
function h=sources()
names={'pfl_train','pfl_spec','pnn_nn_fit','pnn_nn_predict','pnn_predict','pnn_ridge_predict', ...
    'pnn_model_hash','pnn_model_atomic_save','pnn_model_load','pnn_model_exists','pnn_checkpoint','prc_file_hash'};
h=struct('name',{},'sha256',{});
for k=1:numel(names),h(k)=struct('name',names{k},'sha256',pnn_model_hash(which(names{k}),'file'));end
end
function restore_mirror(path,audit)
if audit.mirror_matches,return;end
if isfile(path),movefile(path,[path '.corrupt_' char(javaMethod('randomUUID','java.util.UUID'))]);end
temporary=[tempname(fileparts(path)) '.mat'];copyfile(audit.generation,temporary);movefile(temporary,path);
assert(strcmp(pnn_model_hash(path,'file'),audit.sha256),'pfl:Recovery','Recovered bundle changed.');
end
function finish_lock(bundle,path,outdir)
lock=struct('schema','pfl_selection_lock_v1','bundle_path',path,'bundle_sha256',pnn_model_hash(path,'file'), ...
    'contract_hash',bundle.contract_hash,'selection_uses_test',false, ...
    'new_test_objects_required',true,'non_scientific_smoke',bundle.non_scientific_smoke);
file=fullfile(outdir,'LOCKED_SELECTION_BEFORE_NEW_TEST.mat');
if pnn_model_exists(file)
    old=pnn_model_load(file);assert(isequaln(old.lock,lock),'pfl:Lock','Locked model changed.');
else,pnn_model_atomic_save(file,struct('lock',lock));end
jsonfile=fullfile(outdir,'MODEL_LOCK.json');
if isfile(jsonfile)
    old=jsondecode(fileread(jsonfile));assert(isequaln(old,lock),'pfl:Lock','JSON lock changed.');
else
    temporary=[jsonfile '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
    fid=fopen(temporary,'w','n','UTF-8');assert(fid>=0,'pfl:Write','Cannot save model lock.');
    c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(lock,'PrettyPrint',true));clear c
    assert(~isfile(jsonfile),'pfl:Lock','Lock appeared concurrently.');movefile(temporary,jsonfile);
end
end
function info=make_info(complete,status,hash,path)
info=struct('complete',complete,'status',status,'contract_hash',hash,'modelpath',path);
if complete,info.model_sha256=pnn_model_hash(path,'file');end
end
function progress(outdir,family,candidate,seed,epoch,status)
p=struct('family',family,'candidate',candidate,'seed_index',seed,'epoch',epoch,'status',status,'updated_utc',pnn_utc());
prc_write_json(fullfile(outdir,'training_progress.json'),p);
end
function release(l,c,f),try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end;end
