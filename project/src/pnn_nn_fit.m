function [model,info]=pnn_nn_fit(X,Y,Xval,Yval,options,path)
%PNN_NN_FIT CPU Adam, train-only scaling and exact epoch-boundary resume.
% Y is the physical-unit target correction after the fixed base/skip.
% Output amplitude is undone INSIDE the loss, not used as metric weights.
% All current parameters, Adam moments, RNG, best parameters and history are
% checkpointed every checkpoint_every epochs; stop_after_epoch is a test hook.
o=defaults(options);assert(size(Y,2)==3&&size(Yval,2)==3,'pnn:Target','Three outputs required.');
assert(size(X,1)==size(Y,1)&&size(Xval,1)==size(Yval,1)&&size(X,2)==size(Xval,2), ...
    'pnn:Input','Incompatible matrix sizes.');
assert(size(X,1)>=4&&size(Xval,1)>=2&&all(isfinite([X Y]),'all')&& ...
    all(isfinite([Xval Yval]),'all'),'pnn:Input','Finite train/validation data required.');
identityOptions=rmfield(o,'stop_after_epoch');
sourceFiles={'pnn_nn_fit','pnn_nn_predict','pnn_model_hash','pnn_model_atomic_save','pnn_model_load','pnn_model_exists','pnn_checkpoint','prc_file_hash'};
sources=cell(size(sourceFiles));for k=1:numel(sources),sources{k}=pnn_model_hash(which(sourceFiles{k}),'file');end
identity=struct('options',identityOptions,'data_hash',pnn_model_hash({X,Y,Xval,Yval}), ...
    'source_hashes',{sources},'matlab_release',version('-release'));
callerRng=rng;restore=onCleanup(@()rng(callerRng)); %#ok<NASGU>
mu=mean(X,1);sigma=std(X,0,1);sigma(sigma<1e-10)=1;
amplitude=max(sqrt(mean(Y.^2,1)),o.residual_scale_floor);
Z=single((X-mu)./sigma);Zv=single((Xval-mu)./sigma);
T=single(Y);Tv=single(Yval);
if pnn_model_exists(path)
    saved=pnn_model_load(path);cp=saved.checkpoint;
    assert(strcmp(cp.schema,'pnn_nn_checkpoint_v1')&&isequaln(cp.identity,identity), ...
        'pnn:ResumeMismatch','Candidate data, settings or sources changed.');
    assert(isequaln(cp.mu,mu)&&isequaln(cp.sigma,sigma)&&isequaln(cp.amplitude,amplitude), ...
        'pnn:ResumeMismatch','Stored train-only preprocessing changed.');
    state=cp.state;rng(state.rng);
else
    rng(o.seed,'twister');net=create_network(size(X,2),o.layers);
    [score,smooth]=validation(net,Zv,Tv,amplitude,o);
    state=struct('net',net,'averageGrad',[],'averageSqGrad',[],'iteration',0, ...
        'epoch',0,'bestNet',net,'bestScore',smooth,'bestEpoch',0,'patienceCounter',0, ...
        'history',[0 NaN NaN score smooth smooth],'rng',rng,'status','running','stopping_reason','');
    cp=struct('schema','pnn_nn_checkpoint_v1','identity',identity,'state',state, ...
        'mu',mu,'sigma',sigma,'amplitude',amplitude);
    pnn_model_atomic_save(path,struct('checkpoint',cp));
end
if ~strcmp(state.status,'complete')
    state.status='running';N=size(Z,1);
    for epoch=state.epoch+1:o.max_epochs
        order=randperm(N);sumData=0;sumReg=0;
        for first=1:o.batch_size:N
            ix=order(first:min(first+o.batch_size-1,N));
            [~,grad,dataLoss,penalty]=dlfeval(@gradients,state.net, ...
                dlarray(Z(ix,:).','CB'),dlarray(T(ix,:).','CB'),amplitude,o);
            assert(isfinite(double(extractdata(dataLoss)))&&isfinite(double(extractdata(penalty))), ...
                'pnn:Nonfinite','Nonfinite loss at epoch %d.',epoch);
            state.iteration=state.iteration+1;
            [state.net,state.averageGrad,state.averageSqGrad]=adamupdate(state.net,grad, ...
                state.averageGrad,state.averageSqGrad,state.iteration,o.learn_rate, ...
                o.adam_beta1,o.adam_beta2,o.adam_epsilon);
            sumData=sumData+numel(ix)*double(extractdata(dataLoss));
            sumReg=sumReg+numel(ix)*double(extractdata(penalty));
        end
        [score,smooth]=validation(state.net,Zv,Tv,amplitude,o);
        assert(isfinite(score),'pnn:Nonfinite','Nonfinite validation score.');
        if smooth<state.bestScore
            state.bestScore=smooth;state.bestNet=state.net;state.bestEpoch=epoch;state.patienceCounter=0;
        else
            state.patienceCounter=state.patienceCounter+1;
        end
        state.epoch=epoch;state.rng=rng;
        state.history(end+1,:)=[epoch sumData/N sumReg/N score smooth state.bestScore]; %#ok<AGROW>
        finished=epoch==o.max_epochs||state.patienceCounter>=o.patience;
        paused=epoch>=o.stop_after_epoch&&~finished;
        if finished
            state.status='complete';
            if state.patienceCounter>=o.patience,state.stopping_reason='validation_patience';else,state.stopping_reason='epoch_limit';end
        elseif paused,state.status='paused';state.stopping_reason='test_hook_pause';end
        if mod(epoch,o.checkpoint_every)==0||finished||paused
            cp.state=state;pnn_model_atomic_save(path,struct('checkpoint',cp));
        end
        if finished||paused,break;end
    end
end
model=struct('schema','pnn_nn_v1','net',state.bestNet,'mu',mu,'sigma',sigma, ...
    'amplitude',amplitude,'options',identityOptions,'best_epoch',state.bestEpoch, ...
    'best_validation_score',state.bestScore,'early_stopping_metric','smooth physical mean', ...
    'checkpoint_path',path);
model.parameter_count=sum(cellfun(@numel,state.bestNet.Learnables.Value));
info=struct('complete',strcmp(state.status,'complete'),'status',state.status, ...
    'epoch',state.epoch,'iteration',state.iteration,'best_epoch',state.bestEpoch, ...
    'best_validation_score',state.bestScore,'history',state.history, ...
    'history_columns',{{'epoch','train_smooth_data_loss','train_L2_penalty', ...
    'validation_raw_metric_score','validation_smooth_data_loss','best_smooth_validation_loss'}}, ...
    'checkpoint_path',path,'identity',identity,'stopping_reason',state.stopping_reason);
end

function net=create_network(d,widths)
layers=featureInputLayer(d,'Normalization','none','Name','input');
for k=1:numel(widths)
    layers=[layers;fullyConnectedLayer(widths(k),'Name',sprintf('hidden%d',k)); ...
        tanhLayer('Name',sprintf('tanh%d',k))]; %#ok<AGROW>
end
layers=[layers;fullyConnectedLayer(3,'Name','correction','WeightsInitializer','zeros','BiasInitializer','zeros')];
net=dlnetwork(layers);
end
function [loss,grad,dataLoss,penalty]=gradients(net,X,T,amplitude,o)
P=forward(net,X).*single(amplitude(:));
E=(P-T)./single(o.loss_scales(:));epsilon=single(o.smooth_epsilon);
mass=sqrt(E(1,:).^2+epsilon^2)-epsilon;
com=sqrt(E(2,:).^2+E(3,:).^2+epsilon^2)-epsilon;
dataLoss=mean((mass+com)/2,'all');
penalty=dlarray(single(0));
for k=1:height(net.Learnables)
    if strcmp(net.Learnables.Parameter{k},'Weights')
        penalty=penalty+single(.5*o.lambda)*sum(net.Learnables.Value{k}.^2,'all');
    end
end
loss=dataLoss+penalty;grad=dlgradient(loss,net.Learnables);
end
function [score,smooth]=validation(net,X,T,amplitude,o)
P=double(extractdata(predict(net,dlarray(X.','CB')))).'.*amplitude;
E=(P-double(T))./o.loss_scales;e=o.smooth_epsilon;
score=mean((abs(E(:,1))+sqrt(sum(E(:,2:3).^2,2)))/2);
smooth=mean((sqrt(E(:,1).^2+e^2)-e+sqrt(sum(E(:,2:3).^2,2)+e^2)-e)/2);
end
function o=defaults(o)
d=struct('seed',1430101,'layers',16,'lambda',1e-4,'max_epochs',1500,'patience',150, ...
    'checkpoint_every',5,'batch_size',256,'learn_rate',.001,'adam_beta1',.9, ...
    'adam_beta2',.999,'adam_epsilon',1e-8,'smooth_epsilon',.1, ...
    'loss_scales',[.001 .001 .001],'residual_scale_floor',[1e-5 1e-5 1e-5], ...
    'stop_after_epoch',Inf);
f=fieldnames(d);for k=1:numel(f),if ~isfield(o,f{k}),o.(f{k})=d.(f{k});end,end
assert(all(o.loss_scales>0)&&o.loss_scales(2)==o.loss_scales(3)&& ...
    all(o.residual_scale_floor>0)&&o.lambda>=0&&o.max_epochs>=1&&o.patience>=1, ...
    'pnn:Options','Invalid scales, regularization or stopping settings.');
end
