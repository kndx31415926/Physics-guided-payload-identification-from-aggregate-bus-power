function report=pnn_test_models(outdir)
%PNN_TEST_MODELS Small synthetic contracts; never a scientific performance run.
if nargin<1,outdir=fullfile(tempdir,['pnn_test_' char(datetime('now','Format','yyyyMMdd_HHmmssSSS'))]);end
assert(~isfolder(outdir),'pnn:Test','Use a fresh test output directory.');mkdir(outdir);
source=fileparts(fileparts(mfilename('fullpath')));addpath(fullfile(source,'src'));
assert(license('test','Neural_Network_Toolbox')&&license('test','Statistics_Toolbox'), ...
    'pnn:License','Required MATLAB toolboxes unavailable.');
orphan=fullfile(outdir,'orphan.mat');mkdir([orphan '.generations']);
fid=fopen(fullfile([orphan '.generations'],'pnn_orphan.mat'),'wb');fwrite(fid,uint8(12));fclose(fid);
assert(~pnn_model_exists(orphan),'pnn:Test','Orphan temporary file was trusted.');
rng(740101,'twister');X=randn(80,13);Y=[.001*sin(X(:,1)) .002*X(:,2).*X(:,3) .002*cos(X(:,4))];
Xv=randn(24,13);Yv=[.001*sin(Xv(:,1)) .002*Xv(:,2).*Xv(:,3) .002*cos(Xv(:,4))];
o=struct('seed',740102,'layers',[6 4],'lambda',1e-5,'max_epochs',8,'patience',20, ...
    'batch_size',16,'checkpoint_every',5);
fullPath=fullfile(outdir,'uninterrupted.mat');resumePath=fullfile(outdir,'resumed.mat');
[full,fullInfo]=pnn_nn_fit(X,Y,Xv,Yv,o,fullPath);
partialOptions=o;partialOptions.stop_after_epoch=3;
[~,partialInfo]=pnn_nn_fit(X,Y,Xv,Yv,partialOptions,resumePath);
assert(~partialInfo.complete&&partialInfo.epoch==3,'pnn:Test','Pause did not occur at epoch3.');
[resumed,resumeInfo]=pnn_nn_fit(X,Y,Xv,Yv,o,resumePath);
A=load(fullPath,'checkpoint');B=load(resumePath,'checkpoint');
assert(isequaln(A.checkpoint.state.net.Learnables,B.checkpoint.state.net.Learnables)&& ...
    isequaln(A.checkpoint.state.averageGrad,B.checkpoint.state.averageGrad)&& ...
    isequaln(A.checkpoint.state.averageSqGrad,B.checkpoint.state.averageSqGrad)&& ...
    isequaln(A.checkpoint.state.rng,B.checkpoint.state.rng)&& ...
    isequaln(fullInfo.history,resumeInfo.history),'pnn:Test','Resume differs from uninterrupted training.');
assert(isequaln(pnn_nn_predict(full,Xv),pnn_nn_predict(resumed,Xv)),'pnn:Test','Best predictions differ.');
[~,audit]=pnn_model_load(resumePath);
fid=fopen(audit.generation,'ab');fwrite(fid,uint8(77),'uint8');fclose(fid);
[fallback,recovery]=pnn_model_load(resumePath);
assert(~isempty(recovery.failures)&&fallback.checkpoint.state.epoch==5,'pnn:Test','Corrupt latest generation did not fall back.');
[recovered,recoveredInfo]=pnn_nn_fit(X,Y,Xv,Yv,o,resumePath);
assert(isequaln(pnn_nn_predict(full,Xv),pnn_nn_predict(recovered,Xv))&& ...
    isequaln(fullInfo.history,recoveredInfo.history),'pnn:Test','Fallback resume changed trajectory.');
checkpoints=all(isfield(A.checkpoint.state,{'net','averageGrad','averageSqGrad','rng','bestNet','epoch','history'}));
assert(checkpoints,'pnn:Test','Checkpoint state incomplete.');
assert(all(A.checkpoint.state.history(:,1)==(0:8).'),'pnn:Test','Missing history epochs.');
assert(isequal(A.checkpoint.mu,mean(X,1))&&isequal(A.checkpoint.amplitude, ...
    max(sqrt(mean(Y.^2,1)),[1e-5 1e-5 1e-5])),'pnn:Test','Train-only scaling changed.');
bad=o;bad.lambda=2e-5;must_fail(@()pnn_nn_fit(X,Y,Xv,Yv,bad,resumePath),'pnn:ResumeMismatch');
changed=X;changed(1)=changed(1)+1e-10;
must_fail(@()pnn_nn_fit(changed,Y,Xv,Yv,o,resumePath),'pnn:ResumeMismatch');
ridge=pnn_ridge_fit(X,Y,.001);
Z=(X-ridge.mu)./ridge.sigma;
expected=(Z.'*Z+size(X,1)*.001*eye(13))\(Z.'*(Y-mean(Y,1)));
assert(norm(ridge.beta-expected,'fro')<1e-14,'pnn:Test','Ridge objective changed.');
Xaug=[X randn(80,39)];interaction=pnn_ridge_fit(Xaug,Y,.001,'interaction');
assert(interaction.feature_count==143,'pnn:Test','Interaction feature count must be143.');
N=104;D=struct('X13',[X;Xv],'Xaug',[Xaug;Xv randn(24,39)], ...
    'base',repmat([.15 .10 .001],N,1),'physics8',repmat([.15 .10 .001],N,1), ...
    'theta',repmat([.15 .10 .001],N,1)+[Y;Yv],'usable',true(N,1),'accepted',true(N,1), ...
    'physics8accepted',true(N,1),'object_id',(1:N).','trial_id',(1:N).', ...
    'split',[repmat("train",80,1);repmat("validation",24,1)], ...
    'condition',repmat(["nominal";"mechanical";"electrical";"combined"],26,1));
s=struct('network_seeds',[740111 740112 740113],'nn_layers',{{4}},'nn_lambdas',1e-4, ...
    'ridge_lambdas',[1e-4 .01],'max_epochs',2,'patience',5,'batch_size',32, ...
    'old_iterations',5,'old_patience',3,'skip_alphas',[0 1]);
[trainInfo,bundle]=pnn_train(D,s,fullfile(outdir,'trainer'));
assert(trainInfo.complete&&numel(bundle.methods)==9&&isfile(fullfile(outdir,'trainer','LOCKED_SELECTION_BEFORE_TEST.mat')), ...
    'pnn:Test','Training lock or methods absent.');
obs=rmfield(D,'theta');
for k=1:numel(bundle.methods)
    [pred,detail]=pnn_predict(bundle,obs,bundle.methods(k).name);
    assert(isequal(size(pred),[N 3])&&all(detail.finite),'pnn:Test','Prediction interface failed.');
end
ix=find(strcmp({bundle.methods.name},'ridgeSkipNN13'));fallback=bundle;
fallback.methods(ix).model.alpha=0;
assert(isequaln(pnn_predict(fallback,obs,'ridgeSkipNN13'),pnn_predict(bundle,obs,'ridge13')), ...
    'pnn:Test','Zero skip does not exactly reproduce ridge.');
independent=obs;independent.usable(1)=false;independent.Xaug(1,14)=NaN;
[~,own]=pnn_predict(bundle,independent,'physics8');
assert(own.accepted(1),'pnn:Test','Physics8 incorrectly inherits learner feature failure.');
% Explicit missing estimates must remain failures; rejection must not erase predictions.
invalid=obs;invalid.X13(1,1)=NaN;invalid.accepted(2)=false;
[p,det]=pnn_predict(bundle,invalid,'ridge13');
assert(all(isnan(p(1,:)))&&det.failed(1)&&all(isfinite(p(2,:)))&&~det.accepted(2), ...
    'pnn:Test','Failure/rejection contract failed.');
testD=D;testD.split(1)="test";must_fail(@()pnn_train(testD,s,fullfile(outdir,'test_guard')),'pnn:TestLeakage');
overlap=D;overlap.object_id(81)=1;must_fail(@()pnn_train(overlap,s,fullfile(outdir,'overlap_guard')),'pnn:SplitLeakage');
missing=D;missing.usable(missing.condition=="combined")=false;
must_fail(@()pnn_train(missing,s,fullfile(outdir,'condition_guard')),'pnn:ConditionCoverage');
report=struct('pass',true,'checks',18,'output_dir',outdir,'resume_current_parameters_exact',true, ...
    'resume_adam_moments_exact',true,'resume_rng_exact',true,'resume_history_exact',true, ...
    'three_seed_group_selection',true,'prediction_without_truth',true,'skip_zero_equals_ridge',true, ...
    'test_guard',true,'split_guard',true,'license_neural',true,'license_statistics',true, ...
    'corrupt_generation_preserved_and_fallback_exact',true,'independent_physics_coverage',true);
pnn_model_atomic_save(fullfile(outdir,'TEST_REPORT.mat'),struct('report',report));
fid=fopen(fullfile(outdir,'TEST_REPORT.json'),'w');fwrite(fid,jsonencode(report,'PrettyPrint',true),'char');fclose(fid);
fprintf('PNN_TEST_MODELS_PASS %s\n',outdir);
end
function must_fail(f,id)
try,f();catch err,assert(strcmp(err.identifier,id),'pnn:Test','Unexpected error: %s',err.identifier);return;end
error('pnn:Test','Expected %s was not raised.',id);
end
