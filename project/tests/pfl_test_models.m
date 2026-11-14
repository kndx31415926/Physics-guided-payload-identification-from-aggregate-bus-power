function report=pfl_test_models(outdir)
%PFL_TEST_MODELS Tiny deterministic contracts, not performance evidence.
if nargin<1,outdir=fullfile(tempdir,['pfl_test_' char(javaMethod('randomUUID','java.util.UUID'))]);end
assert(~isfolder(outdir),'pfl:Test','Use a new output directory.');mkdir(outdir);
addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))),'src'));
caller=rng;cleanup=onCleanup(@()rng(caller)); %#ok<NASGU>
rng(811001,'twister');N=32;X=randn(N,13);base=repmat([.15 .10 .001],N,1);
Y=[.002*sin(X(:,1)) .001*X(:,2).*X(:,3) .001*cos(X(:,4))];
D=struct('X13',X,'Xaug',[X randn(N,39)],'base',base,'theta',base+Y, ...
    'usable',true(N,1),'accepted',true(N,1),'object_id',(1:N).','trial_id',(1:N).', ...
    'split',[repmat("train",24,1);repmat("validation",8,1)], ...
    'condition',repmat(["nominal";"mechanical";"electrical";"combined"],8,1));
ridge=pnn_ridge_fit(X(1:24,:),Y(1:24,:),1e-4,'linear');
old=struct('network_seeds',[811011 811012 811013],'nn_layers',{{4,[6 4]}}, ...
    'nn_lambdas',[1e-6 1e-4 1e-2],'skip_alphas',[0 .25 .5 .75 1], ...
    'max_epochs',1500,'patience',150,'checkpoint_every',5,'batch_size',256,'learn_rate',.001, ...
    'adam_beta1',.9,'adam_beta2',.999,'adam_epsilon',1e-8,'smooth_epsilon',.1, ...
    'loss_scales',[.001 .001 .001],'residual_scale_floor',[1e-5 1e-5 1e-5], ...
    'required_conditions',{{'nominal','mechanical','electrical','combined'}}, ...
    'min_eligible_per_condition',100,'bounds',[.06 .25;.04 .20;-.025 .025]);
methods=struct('name','ridge13','kind','ridge','input','X13','model',ridge,'selection',struct());
members={struct('options',struct('layers',4))};
methods(2)=struct('name','ridgeSkipNN13','kind','NN','input','X13', ...
    'model',struct('skip',ridge,'members',{members},'alpha',.5),'selection',struct('lambda',1e-4));
anchor=struct('spec',old,'primary_method','ridgeSkipNN13','methods',methods,'contract_hash','synthetic_pfl_fixture_v1');
declared=pfl_spec(anchor,'futurefull');
assert(numel(declared.linear_lambdas)==6&&numel(declared.nn_layers)*numel(declared.nn_lambdas)==6, ...
    'pfl:Test','Full search budgets differ.');
must_fail(@()pfl_train(D,anchor,declared,fullfile(outdir,'forbidden_full')),'pfl:FullNotAuthorized');
must_fail(@()pfl_run('futurefull',fullfile(outdir,'forbidden_runner'),struct()),'pfl:FullNotAuthorized');
s=pfl_spec(anchor,'tinySmoke');s.nn_layers={4};s.nn_lambdas=1e-4;s.linear_lambdas=1e-4;
s.skip_alphas=[0 .5 1];s.max_epochs=4;s.patience=10;s.checkpoint_every=2;s.batch_size=8;
[fullInfo,full]=pfl_train(D,anchor,s,fullfile(outdir,'full'));
partial=s;partial.stop_after_epoch=1;
[pausedInfo,pausedBundle]=pfl_train(D,anchor,partial,fullfile(outdir,'resumed'));
assert(~pausedInfo.complete&&isempty(pausedBundle)&& ...
    ~isfile(fullfile(outdir,'resumed','MODEL_LOCK.json')),'pfl:Test','A partial candidate was locked.');
[resumeInfo,resumed]=pfl_train(D,anchor,s,fullfile(outdir,'resumed'));
assert(fullInfo.complete&&resumeInfo.complete&&numel(full.methods)==5,'pfl:Test','Training did not seal five methods.');
obs=rmfield(D,'theta');poisoned=obs;poisoned.theta=nan(N,3);
for k=1:numel(full.methods)
    a=pnn_predict(full,obs,k);b=pnn_predict(resumed,obs,k);
    assert(isequaln(a,b)&&isequaln(a,pnn_predict(full,poisoned,k)),'pfl:Test','Resume or truth-free prediction changed.');
end
a=full.methods(strcmp({full.methods.name},'affine_fixed')).model;
b=full.methods(strcmp({full.methods.name},'nonlinear_fixed')).model;
assert(a.alpha==s.fixed_alpha&&b.alpha==s.fixed_alpha&&isequaln(a.skip,b.skip),'pfl:Test','Fixed pair skip/alpha differ.');
for k=1:numel(a.members)
    ao=a.members{k}.options;bo=b.members{k}.options;
    assert(isempty(ao.layers)&&isequal(bo.layers,s.fixed_layers)&& ...
        isequaln(rmfield(ao,'layers'),rmfield(bo,'layers')),'pfl:Test','Fixed options differ beyond function class.');
    assert(isequaln(a.members{k}.mu,b.members{k}.mu)&&isequaln(a.members{k}.sigma,b.members{k}.sigma)&& ...
        isequaln(a.members{k}.amplitude,b.members{k}.amplitude),'pfl:Test','Fixed pair preprocessing differs.');
    target=D.theta-D.base-pnn_ridge_predict(ridge,X);
    assert(isequaln(a.members{k}.mu,mean(X(1:24,:),1))&& ...
        isequaln(a.members{k}.amplitude,max(sqrt(mean(target(1:24,:).^2,1)),s.residual_scale_floor)), ...
        'pfl:Test','Preprocessing is not train-only.');
    assert(a.members{k}.parameter_count==3*(size(X,2)+1),'pfl:Test','Affine network has unexpected hidden parameters.');
end
% Exact current weights, moments, RNG, and history after epoch-boundary resume.
fa=load(fullfile(outdir,'full','candidates','affine_c01_seed811011.mat'),'checkpoint');
fb=load(fullfile(outdir,'resumed','candidates','affine_c01_seed811011.mat'),'checkpoint');
assert(isequaln(fa.checkpoint.state.net.Learnables,fb.checkpoint.state.net.Learnables)&& ...
    isequaln(fa.checkpoint.state.averageGrad,fb.checkpoint.state.averageGrad)&& ...
    isequaln(fa.checkpoint.state.averageSqGrad,fb.checkpoint.state.averageSqGrad)&& ...
    isequaln(fa.checkpoint.state.rng,fb.checkpoint.state.rng)&& ...
    isequaln(fa.checkpoint.state.history,fb.checkpoint.state.history),'pfl:Test','Epoch resume is not exact.');
xa=X(1:4,:);xb=X(5:8,:);ya=pnn_nn_predict(a.members{1},xa);yb=pnn_nn_predict(a.members{1},xb);
ym=pnn_nn_predict(a.members{1},(xa+xb)/2);
assert(max(abs(ym-(ya+yb)/2),[],'all')<1e-8,'pfl:Test','The linear comparator is not affine.');
zero=full;for k=2:numel(zero.methods),zero.methods(k).model.alpha=0;end
for k=2:numel(zero.methods)
    assert(isequaln(pnn_predict(zero,obs,k),pnn_predict(zero,obs,'ridge_anchor')),'pfl:Test','alpha zero differs from ridge.');
end
invalid=D;invalid.split(1)="test";
must_fail(@()pfl_train(invalid,anchor,s,fullfile(outdir,'test_leak')),'pfl:TestLeakage');
invalid=D;invalid.object_id(25)=invalid.object_id(1);
must_fail(@()pfl_train(invalid,anchor,s,fullfile(outdir,'overlap')),'pfl:ObjectUnit');
changed=D;changed.theta(1,1)=changed.theta(1,1)+1e-8;
must_fail(@()pfl_train(changed,anchor,s,fullfile(outdir,'full')),'pfl:ResumeMismatch');
changed=s;changed.linear_lambdas=1e-3;
must_fail(@()pfl_train(D,anchor,changed,fullfile(outdir,'bad_grid')),'pfl:Budget');
% Candidate identity includes empty/nonempty layers, even with all other options equal.
o=a.members{1}.options;o.layers=4;
target=D.theta-D.base-pnn_ridge_predict(ridge,X);
must_fail(@()pnn_nn_fit(X(1:24,:),target(1:24,:),X(25:end,:),target(25:end,:),o, ...
    fullfile(outdir,'full','candidates','affine_c01_seed811011.mat')),'pnn:ResumeMismatch');
report=struct('pass',true,'scientific_performance_run',false,'output_dir',outdir, ...
    'affine_function_class',true,'matched_fixed_pair_options',true,'train_only_scaling',true, ...
    'epoch_resume_exact',true,'truth_free_prediction',true,'alpha_zero_equals_ridge',true, ...
    'test_and_object_leakage_rejected',true,'changed_contract_rejected',true, ...
    'layers_in_checkpoint_identity',true,'full_run_disabled_by_default',true);
pnn_model_atomic_save(fullfile(outdir,'TEST_REPORT.mat'),struct('report',report));
fprintf('PFL_TEST_MODELS_PASS %s\n',outdir);
end
function must_fail(f,id)
try,f();catch err,assert(strcmp(err.identifier,id),'pfl:Test','Expected %s, got %s: %s',id,err.identifier,err.message);return;end
error('pfl:Test','Expected %s was not raised.',id);
end
