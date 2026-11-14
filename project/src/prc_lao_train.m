function [model,info]=prc_lao_train(D,train_idx,val_idx,spec,outdir)
%PRC_LAO_TRAIN Sequential Lao T/T-A architecture adaptation in MATLAB.
% Deep Learning Toolbox custom loop: dlarray/dlgradient/adamupdate, float64.
% Reads only explicit train/validation rows. No simulated actuator torque.
% Validation selects epochs using deployed clipped SVD theta, predicted-mass
% COM denominator. Attention training alone uses true TRAIN mass denominator.
spec=defaults(spec);outdir=char(outdir);maxNumCompThreads(1);
if ~exist(outdir,'dir'),mkdir(outdir);end
started=tic;
try
    [model,info]=train_impl(D,train_idx(:),val_idx(:),spec,outdir,started);
catch err
    write_progress(outdir,struct('stage','failed','message',err.message,'identifier',err.identifier));
    rethrow(err);
end
end

function [model,info]=train_impl(D,tr,va,spec,outdir,started)
assert(all(isfield(D,{'object_id','split','theta','state','g0','Y','tau_label','usable'})), ...
    'prc:LaoData','Training dataset fields missing.');
assert(isempty(intersect(tr,va))&&numel(unique(tr))==numel(tr)&&numel(unique(va))==numel(va), ...
    'prc:LaoSplit','Train and validation rows must be disjoint and unique.');
assert(all(string(D.split(tr))=="train")&&all(string(D.split(va))=="validation"), ...
    'prc:LaoSplit','Explicit indices must select only train/validation objects.');
planned_train=tr;planned_val=va;tr=tr(logical(D.usable(tr)));va=va(logical(D.usable(va)));
assert(numel(tr)>=2&&numel(va)>=1,'prc:LaoData','Insufficient usable objects.');
used=[tr;va];check_data(D,used);labels=analytic_labels(D,used);
assert(max(abs(labels-double(D.tau_label(used,:,:))),[],'all')<1e-8,'prc:LaoLabels', ...
    'tau_label must equal analytic static gravity from known training/validation parameters.');
norms=training_normalization(D,tr);source=source_record();
contract=struct('schema','prc_lao_contract_v1','spec',spec,'train_ids',D.object_id(tr), ...
    'validation_ids',D.object_id(va),'planned_train_ids',D.object_id(planned_train), ...
    'planned_validation_ids',D.object_id(planned_val),'normalization',norms,'source',source, ...
    'state',D.state(used,:,:,:),'g0',D.g0(used,:,:),'Y',D.Y(used,:,:,:), ...
    'theta',D.theta(used,:),'analytic_tau',labels);
contract_path=fullfile(outdir,'TRAIN_VALIDATION_CONTRACT.mat');
if exist(contract_path,'file')
    previous=load(contract_path,'contract');assert(isequaln(previous.contract,contract), ...
        'prc:LaoResumeMismatch','Data, scaling, specification or source changed; use a fresh directory.');
else
    prc_lao_atomic_save(contract_path,struct('contract',contract));
end
% Keep training copies separate from the runner's immutable source_snapshot.
snapshot=fullfile(outdir,'training_source');if ~exist(snapshot,'dir'),mkdir(snapshot);end
for k=1:numel(source),copyfile(source(k).path,snapshot);end
model=base_model(spec,norms);model.train_object_ids=D.object_id(tr);model.validation_object_ids=D.object_id(va);
model.planned_train_object_ids=D.object_id(planned_train);model.planned_validation_object_ids=D.object_id(planned_val);
Xtrain=prc_lao_inputs(D.state(tr,:,:,:),norms);Xval=prc_lao_inputs(D.state(va,:,:,:),norms);
Ltrain=reshape(permute(analytic_labels(D,tr),[3 2 1]),4,[])/norms.torque_scale;
Lval=reshape(permute(analytic_labels(D,va),[3 2 1]),4,[])/norms.torque_scale;
torque_gradient=dlaccelerate(@torque_loss);attention_gradient=dlaccelerate(@attention_loss);
selection=struct([]);last_gradient=nan(numel(spec.network_seeds),2);
for s=1:numel(spec.network_seeds)
    seed=spec.network_seeds(s);
    checkpoint=fullfile(outdir,sprintf('seed_%d_torque_checkpoint.mat',seed));
    C=load_stage(checkpoint,seed,'torque');
    for epoch=C.epoch+1:spec.torque_epochs
        rng(seed+epoch,'twister');order=randperm(size(Xtrain,3));total_loss=0;total_n=0;gn=0;
        for first=1:spec.torque_batch:numel(order)
            batch=order(first:min(first+spec.torque_batch-1,numel(order)));
            [loss,grad,g]=dlfeval(torque_gradient,C.parameters,dlarray(Xtrain(:,:,batch)),dlarray(Ltrain(:,batch)));
            value=double(extractdata(loss));gn=double(extractdata(g));
            assert(isfinite(value)&&isfinite(gn),'prc:LaoGradient','Nonfinite torque loss/gradient.');
            C.iteration=C.iteration+1;
            [C.parameters,C.average,C.average_sq]=adamupdate(C.parameters,grad,C.average,C.average_sq, ...
                C.iteration,spec.lr);
            total_loss=total_loss+value*numel(batch);total_n=total_n+numel(batch);
        end
        tmp=single_model(model,C.parameters,[],seed);
        v=prc_lao_predict(tmp,D,va,'uniform');[score,rawscore]=parameter_score(v,D.theta(va,:),spec);
        vp=double(extractdata(prc_lao_forward(C.parameters,dlarray(Xval),'torque')));
        torque_mse=mean((vp-Lval).^2,'all');
        C=finish_epoch(C,epoch,total_loss/total_n,score,rawscore,torque_mse,gn);
        prc_lao_atomic_save(checkpoint,struct('checkpoint',C));
        stage_progress(outdir,seed,'torque',epoch,spec.torque_epochs,C,toc(started));
    end
    assert(~isempty(C.best_parameters)&&isfinite(C.best_score),'prc:LaoSelection','No finite torque candidate.');
    torque=C.best_parameters;torque_epoch=C.best_epoch;torque_score=C.best_score;
    last_gradient(s,1)=C.history(end).gradient_norm;
    % Freeze the selected torque model before attention training.
    tau=double(extractdata(prc_lao_forward(torque,dlarray(Xtrain),'torque')))*norms.torque_scale;
    free=reshape(permute(double(D.g0(tr,:,:)),[3 2 1]),4,[]);
    R=reshape(tau-free,32,numel(tr));
    Y=reshape(permute(double(D.Y(tr,:,:,:)),[3 2 4 1]),32,3,numel(tr));
    theta=double(D.theta(tr,:)).';
    checkpoint=fullfile(outdir,sprintf('seed_%d_attention_checkpoint.mat',seed));
    A=load_stage(checkpoint,seed,'attention');
    for epoch=A.epoch+1:spec.attention_epochs
        rng(seed+1000000+epoch,'twister');order=randperm(numel(tr));total_loss=0;total_n=0;gn=0;
        for first=1:spec.attention_batch:numel(order)
            batch=order(first:min(first+spec.attention_batch-1,numel(order)));
            samples=reshape((1:8).'+8*(batch-1),1,[]);
            [loss,grad,g]=dlfeval(attention_gradient,A.parameters,dlarray(Xtrain(:,:,samples)), ...
                Y(:,:,batch),R(:,batch),theta(:,batch),norms.Y_column_scale,spec.scale,spec.ridge,spec.w_com);
            value=double(extractdata(loss));gn=double(extractdata(g));
            assert(isfinite(value)&&isfinite(gn),'prc:LaoGradient','Nonfinite attention loss/gradient.');
            A.iteration=A.iteration+1;
            [A.parameters,A.average,A.average_sq]=adamupdate(A.parameters,grad,A.average,A.average_sq, ...
                A.iteration,spec.attention_lr);
            total_loss=total_loss+value*numel(batch);total_n=total_n+numel(batch);
        end
        tmp=single_model(model,torque,A.parameters,seed);
        v=prc_lao_predict(tmp,D,va,'attention');[score,rawscore]=parameter_score(v,D.theta(va,:),spec);
        A=finish_epoch(A,epoch,total_loss/total_n,score,rawscore,NaN,gn);
        prc_lao_atomic_save(checkpoint,struct('checkpoint',A));
        stage_progress(outdir,seed,'attention',epoch,spec.attention_epochs,A,toc(started));
    end
    assert(~isempty(A.best_parameters)&&isfinite(A.best_score),'prc:LaoSelection','No finite attention candidate.');
    last_gradient(s,2)=A.history(end).gradient_norm;
    learner=struct('seed',seed,'torque',torque,'attention',A.best_parameters, ...
        'torque_epoch',torque_epoch,'attention_epoch',A.best_epoch, ...
        'torque_validation_score',torque_score,'attention_validation_score',A.best_score);
    model.learners{s}=learner;
    prc_lao_atomic_save(fullfile(outdir,sprintf('seed_%d_selected.mat',seed)),struct('learner',learner));
    selection=[selection;struct('seed',seed,'stage','torque','selected_epoch',torque_epoch, ...
        'validation_deployed_score',torque_score,'total_epochs',spec.torque_epochs); ...
        struct('seed',seed,'stage','attention','selected_epoch',A.best_epoch, ...
        'validation_deployed_score',A.best_score,'total_epochs',spec.attention_epochs)]; %#ok<AGROW>
    writetable(struct2table(C.history),fullfile(outdir,sprintf('seed_%d_torque_history.csv',seed)));
    writetable(struct2table(A.history),fullfile(outdir,sprintf('seed_%d_attention_history.csv',seed)));
end
info=struct('complete',true,'outdir',outdir,'elapsed_s',toc(started), ...
    'train_planned',numel(planned_train),'train_used',numel(tr),'validation_planned',numel(planned_val), ...
    'validation_used',numel(va),'network_seeds',spec.network_seeds,'last_gradient_norms',last_gradient, ...
    'selection',struct2table(selection),'test_read',false,'model_path',fullfile(outdir,'lao_model.mat'), ...
    'prediction_contract','theta_raw Nx3xS; theta_clipped Nx3xS; theta Nx3 clipped-seed mean; tau/weights Nx8x4xS', ...
    'scope',model.scope);
lock=struct('created_at',timestamp(),'selections',info.selection,'test_read',false, ...
    'train_ids',model.train_object_ids,'validation_ids',model.validation_object_ids, ...
    'epoch_selection','Minimum validation loss of clipped SVD deployed theta, with predicted mass denominator');
prc_lao_atomic_save(fullfile(outdir,'LAO_SELECTION_LOCK.mat'),struct('lock',lock));
prc_lao_atomic_save(info.model_path,struct('model',model,'info',info));
writetable(info.selection,fullfile(outdir,'lao_selection.csv'));
write_progress(outdir,struct('stage','complete','elapsed_s',info.elapsed_s,'model_path',info.model_path));
end

function [loss,grad,norm_grad]=torque_loss(P,X,T)
pred=prc_lao_forward(P,X,'torque');loss=mean((pred-T).^2,'all');
grad=dlgradient(loss,P);norm_grad=gradient_norm(grad);
end
function [loss,grad,norm_grad]=attention_loss(P,X,Y,R,T,column_scale,scale,ridge,wcom)
w=prc_lao_forward(P,X,'attention');w=reshape(w,32,size(T,2));
phi=prc_lao_solve_dl(Y,R,w,column_scale,ridge);
mass_error=(phi(1,:)-T(1,:))/scale(1);
% True mass is allowed ONLY here on supervised training objects.
com_error=(phi(2:3,:)./T(1,:)-T(2:3,:))./scale(2:3).';
loss=mean(mass_error.^2+wcom*sum(com_error.^2,1),'all');
grad=dlgradient(loss,P);norm_grad=gradient_norm(grad);
end
function g=gradient_norm(grad)
names=fieldnames(grad);g=dlarray(0);
for k=1:numel(names),g=g+sum(grad.(names{k}).^2,'all');end
g=sqrt(g);
end
function C=load_stage(path,seed,stage)
if exist(path,'file')
    saved=load(path,'checkpoint');C=saved.checkpoint;
    assert(C.seed==seed&&strcmp(C.stage,stage),'prc:LaoResumeMismatch','Checkpoint identity mismatch.');return
end
offset=0;if strcmp(stage,'attention'),offset=100000000;end
rng(seed+offset,'twister');P=initialize(stage);
C=struct('schema','prc_lao_epoch_v1','seed',seed,'stage',stage,'epoch',0,'iteration',0, ...
    'parameters',P,'average',[],'average_sq',[],'best_parameters',[], ...
    'best_epoch',0,'best_score',Inf,'history',struct([]));
end
function P=initialize(kind)
P=struct;
for j=1:4
    prefix=sprintf('j%d_',j);P.([prefix 'w1'])=weight(12,4);P.([prefix 'b1'])=dlarray(zeros(12,1));
    P.([prefix 'w2'])=weight(12,12);P.([prefix 'b2'])=dlarray(zeros(12,1));
end
if strcmp(kind,'torque')
    P.h1w=weight(64,48);P.h1b=dlarray(zeros(64,1));P.h2w=weight(64,64);P.h2b=dlarray(zeros(64,1));
    P.h3w=weight(4,64);P.h3b=dlarray(zeros(4,1));
else
    P.sw1=weight(32,16);P.sb1=dlarray(zeros(32,1));P.sw2=weight(1,32);P.sb2=dlarray(zeros(1,1));
end
end
function W=weight(out,in)
W=dlarray(sqrt(2/in)*randn(out,in));
end
function C=finish_epoch(C,epoch,loss,score,rawscore,torque_mse,grad)
C.epoch=epoch;
row=struct('epoch',epoch,'train_loss',loss,'validation_score',score,'validation_raw_score',rawscore, ...
    'validation_torque_mse_scaled',torque_mse,'gradient_norm',grad,'optimizer_steps',C.iteration);
if isempty(C.history),C.history=row;else,C.history(end+1)=row;end
if isempty(C.best_parameters)||score<C.best_score
    C.best_score=score;C.best_epoch=epoch;C.best_parameters=C.parameters;
end
end
function [score,rawscore]=parameter_score(pred,T,spec)
error=(pred.theta-double(T))./spec.scale;raw=(pred.theta_raw_mean-double(T))./spec.scale;
score=mean(error(:,1).^2+spec.w_com*sum(error(:,2:3).^2,2));
rawscore=mean(raw(:,1).^2+spec.w_com*sum(raw(:,2:3).^2,2));
if ~isfinite(score),score=Inf;end
if ~isfinite(rawscore),rawscore=Inf;end
end
function model=base_model(spec,norms)
model=struct('schema','prc_lao_adaptation_v1','spec',spec,'normalization',norms, ...
    'seeds',spec.network_seeds,'learners',{cell(1,numel(spec.network_seeds))}, ...
    'source_url','https://arxiv.org/html/2104.09858v2', ...
    'torque_architecture','4 independent 4-12-12 ReLU; concat48-64-64-4 linear output', ...
    'attention_architecture','4 separate 4-12-12 ReLU; append onehot4; shared16-32-1; per-pose joint softmax', ...
    'scope','Adaptation, not exact reproduction: known frame, vertical-yaw 4R, PID, eight poses, planar m/cx/cz', ...
    'label_scope','Known train/validation objects produce analytic gravity labels; never actuator torque', ...
    'loss_scope','Mass/span L2 + 0.3 SUM of two COM/span L2; true TRAIN mass denominator only', ...
    'solver_scope','Normalized-column tiny-ridge training; unregularized weighted-SVD validation/prediction');
end
function model=single_model(model,torque,attention,seed)
model.seeds=seed;model.learners={struct('torque',torque,'attention',attention,'seed',seed)};
end
function norms=training_normalization(D,tr)
X=reshape(permute(double(D.state(tr,:,:,:)),[4 3 2 1]),4,4,[]);
qmin=zeros(1,4);qspan=qmin;escale=qmin;
for j=1:4
    q=reshape(X(1,j,:),1,[]);e=reshape(X(2,j,:),1,[]);
    qmin(j)=min(q);qspan(j)=max(q)-min(q);if qspan(j)<1e-12,qspan(j)=1;end
    escale(j)=max(abs(e));if escale(j)<1e-12,escale(j)=1;end
end
L=analytic_labels(D,tr);ts=max(abs(L),[],'all');if ts<1e-12,ts=1;end
Y=reshape(double(D.Y(tr,:,:,:)),[],3);ys=sqrt(mean(Y.^2,1));
assert(all(ys>1e-12),'prc:LaoGeometry','Unexcited parameter column in training design.');
norms=struct('q_min',qmin,'q_span',qspan,'error_scale',escale,'torque_scale',ts, ...
    'Y_column_scale',ys,'fitted_on','Explicit usable training rows only', ...
    'torque_scaling','Global train max absolute torque; per-joint train max absolute position error');
end
function labels=analytic_labels(D,idx)
T=double(D.theta(idx,:));phi=[T(:,1) T(:,1).*T(:,2) T(:,1).*T(:,3)];labels=double(D.g0(idx,:,:));
for h=1:3,labels=labels+double(D.Y(idx,:,:,h)).*reshape(phi(:,h),[],1,1);end
end
function check_data(D,idx)
assert(isequal(size(D.state,2:4),[8 4 4])&&isequal(size(D.Y,2:4),[8 4 3])&& ...
    isequal(size(D.g0,2:3),[8 4])&&size(D.theta,2)==3,'prc:LaoShape','Dataset shape mismatch.');
assert(all(isfinite(D.state(idx,:,:,:)),'all')&&all(isfinite(D.g0(idx,:,:)),'all')&& ...
    all(isfinite(D.Y(idx,:,:,:)),'all')&&all(isfinite(D.theta(idx,:)),'all')&& ...
    all(D.theta(idx,1)>0),'prc:LaoFinite','Invalid training data or known mass.');
directions=double(D.state(idx,:,:,3:4));
% Unknown direction/initial pose is [0,0]; do not fabricate an approach sign.
assert(all(directions==0|directions==1,'all')&&all(sum(directions,4)<=1,'all'), ...
    'prc:LaoDirection','Direction channels must be binary, with at most one active sign.');
end
function spec=defaults(spec)
v=struct('network_seeds',[830101 830102 830103],'torque_epochs',300,'attention_epochs',30, ...
    'lr',.0003,'attention_lr',.0001,'torque_batch',256,'attention_batch',32, ...
    'scale',[.14 .14 .036],'w_com',.3,'ridge',1e-10,'mass_division_floor',1e-8, ...
    'max_condition',1e8,'bounds',[.06 .25;.04 .20;-.025 .025]);
if isfield(spec,'seeds')&&~isfield(spec,'network_seeds'),spec.network_seeds=spec.seeds;end
f=fieldnames(v);for k=1:numel(f),if isfield(spec,f{k}),v.(f{k})=spec.(f{k});end,end
spec=v;spec.network_seeds=double(spec.network_seeds(:).');spec.scale=double(spec.scale(:).');
assert(~isempty(spec.network_seeds)&&numel(unique(spec.network_seeds))==numel(spec.network_seeds)&& ...
    numel(spec.scale)==3&&all(spec.scale>0)&&isequal(size(spec.bounds),[3 2]),'prc:LaoSpec','Invalid specification.');
assert(spec.torque_epochs>=1&&spec.attention_epochs>=1&&spec.torque_batch>=1&&spec.attention_batch>=1&& ...
    spec.lr>0&&spec.attention_lr>0&&spec.ridge>0,'prc:LaoSpec','Invalid optimizer settings.');
end
function source=source_record()
names={'prc_lao_train','prc_lao_predict','prc_lao_forward','prc_lao_inputs','prc_lao_solve_dl','prc_lao_atomic_save'};
source=struct('path',{},'text',{});
for k=1:numel(names),p=which(names{k});source(k)=struct('path',p,'text',fileread(p));end %#ok<AGROW>
end
function stage_progress(outdir,seed,stage,epoch,total,C,elapsed)
data=struct('stage',stage,'seed',seed,'epoch',epoch,'epochs',total, ...
    'train_loss',C.history(end).train_loss,'validation_score',C.history(end).validation_score, ...
    'best_epoch',C.best_epoch,'best_validation_score',C.best_score,'elapsed_s',elapsed);
write_progress(outdir,data);
fprintf('Lao seed%d %s epoch %d/%d train %.6g val-deployed %.6g best %d elapsed %.1fs\n', ...
    seed,stage,epoch,total,data.train_loss,data.validation_score,C.best_epoch,elapsed);
end
function write_progress(outdir,data)
data.updated_at=timestamp();path=fullfile(outdir,'progress_lao.json');tmp=[tempname(outdir) '.tmp'];
fid=fopen(tmp,'w','n','UTF-8');assert(fid>=0,'prc:LaoIO','Cannot write progress file.');
fprintf(fid,'%s\n',jsonencode(data,'PrettyPrint',true));fclose(fid);
[ok,msg]=movefile(tmp,path,'f');assert(ok,'prc:LaoIO','%s',msg);
end
function s=timestamp()
s=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
end
