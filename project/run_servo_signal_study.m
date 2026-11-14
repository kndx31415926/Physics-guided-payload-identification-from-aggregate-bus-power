function results=run_servo_signal_study(data_name,analysis_name)
% Fair signal ablations trained on the same full-servo objects and splits.
% Test objects never select hyperparameters or network initializations.
if nargin<1,data_name='servo_signal_study_v2';end
if nargin<2,analysis_name='analysis';end
cfg=startup_bpil();root=fullfile(cfg.root,'results',data_name);
assert(exist(fullfile(root,'DATA_COMPLETE.txt'),'file')==2,'bpil:Incomplete','Dataset not complete');
saved=load(fullfile(root,'configuration.mat'),'cfg');cfg=saved.cfg;
out=fullfile(root,analysis_name);assert(~exist(out,'dir'),'bpil:Exists','Analysis exists');mkdir(out);
copyfile(fullfile(cfg.root,'run_servo_signal_study.m'),out);
M=readtable(fullfile(root,'manifest.csv'),'TextType','string');
O=readtable(fullfile(root,'objects.csv'),'TextType','string');
eta=struct('coefficients',cfg.legacy.power.coefficients);
N=height(O);T=[O.mass_kg O.cx_m O.cz_m];scale=[.14 .14 .036];
Xq=[];Xp=[];Xr=[];base=nan(height(M),3);usable=false(height(M),1);
physical=usable;accepted=usable;prior=nan(N,3);Xeq=nan(N,36);
old=load(fullfile(cfg.root,'results','feasibility_nominal_v1','offline_student.mat'),'student');
for i=1:height(M)
    S=load(fullfile(root,'trials',sprintf('trial_%03d.mat',i)));r=S.record;
    assert(r.trial_id==i&&r.object_id==M.object_id(i)&&strcmp(r.split,M.split(i)), ...
        'bpil:Manifest','Trial record/manifest mismatch');
    assert(strcmp(r.probe_id,sprintf('probe_%02d',M.probe_index(i))), ...
        'bpil:Manifest','Trial probe mismatch');
    if ~isempty(r.error),continue;end
    physical(i)=r.truth.physical_success;
    usable(i)=all(r.obs.stationary)&&all(isfinite(r.obs.plateau_q),'all')&&all(isfinite(r.obs.plateau_P));
    teacher=bpil_teacher(cfg,r.obs,eta,[]);base(i,:)=teacher.theta;accepted(i)=teacher.accepted;
    if i<=N&&usable(i)
        [a,b]=features(r.obs,cfg);
        if isempty(Xq),Xq=nan(N,numel(a));Xp=nan(N,numel(b));Xr=nan(N,13);end
        Xq(i,:)=a;Xp(i,:)=b;
        predicted=bpil_predict_power(cfg,r.obs.plateau_q,base(i,:),eta);
        Xr(i,:)=[base(i,:)./scale,(r.obs.plateau_P-predicted).'/cfg.ident.power_sigma_W, ...
            teacher.rmse_W,teacher.validation_rmse_W];
        Xeq(i,:)=bpil_features(r.obs,eta);
        prior(i,:)=bpil_student_predict(old.student,Xeq(i,:));
    end
end
status=table(M.trial_id,M.object_id,M.split,M.probe_index,physical,usable,accepted, ...
    'VariableNames',{'trial_id','object_id','split','probe_index','physical_success','observation_usable','teacher_accepted'});
writetable(status,fullfile(out,'trial_status.csv'));
train=find(O.split=="train"&usable(1:N));val=find(O.split=="validation"&usable(1:N));test=find(O.split=="test"&usable(1:N));
assert(numel(train)>=30&&numel(val)>=8&&numel(test)>=8,'bpil:Data','Insufficient usable objects');
% Keep every failure in status; failures never become training observations.
Xp_shuffle=Xp;rng(661002,'twister');
for ids={train,val,test},ix=ids{1};Xp_shuffle(ix,:)=Xp(ix(randperm(numel(ix))),:);end
inputs={Xq,[Xq Xp],Xp,[Xq Xp_shuffle],Xr,prior./scale};
names={'encoder_only','encoder_plus_power','power_only_fixed_motion', ...
    'encoder_plus_shuffled_power','physics_residual_nn','pretrained_calibration_nn'};
layers={[8],[16 8]};lambdas=[.001 .1];seeds=[77001 77002 77003];
allrows=struct([]);selections=struct([]);students=cell(numel(names),numel(seeds));
ensembles=nan(numel(test),3,numel(names));
for mode=1:numel(names)
    X=inputs{mode};keep=std(X(train,:),0,1)>1e-10;X=X(:,keep);
    target=T./scale;offset=zeros(N,3);
    if mode==5,offset=base(1:N,:);target=(T-offset)./scale;end
    if mode==6,offset=prior;target=(T-offset)./scale;end
    predseeds=nan(numel(test),3,numel(seeds));
    for s=1:numel(seeds)
        best=Inf;bestmodel=[];bestconfig=[];
        for l=1:numel(layers)
            for w=1:numel(lambdas)
                [model,training]=fit_validated(X(train,:),target(train,:), ...
                    X(val,:),target(val,:),layers{l},lambdas(w),seeds(s));
                vp=clip(predict(model,X(val,:)).*scale+offset(val,:),cfg.ident.bounds);
                loss=mean(((vp-T(val,:))./scale).^2,'all');
                row=struct('method',names{mode},'seed',seeds(s),'layers',mat2str(layers{l}), ...
                    'lambda',lambdas(w),'feature_count',sum(keep),'validation_normalized_mse',loss, ...
                    'stop_iterations',training.stop_iterations, ...
                    'chosen_iterations',training.chosen_iterations, ...
                    'stopping_reason',training.stopping_reason);
                if isempty(selections),selections=row;else,selections(end+1)=row;end %#ok<AGROW>
                if loss<best,best=loss;bestmodel=model;bestconfig=row;end
            end
        end
        % Test is touched only after the validation-selected candidate is fixed.
        pred=clip(predict(bestmodel,X(test,:)).*scale+offset(test,:),cfg.ident.bounds);
        students{mode,s}=struct('model',bestmodel,'columns',keep,'selection',bestconfig);
        predseeds(:,:,s)=pred;
        allrows=append(allrows,names{mode},seeds(s),test,T,pred,true(numel(test),1));
        fprintf('%s seed %d: selected %s lambda %.3g; validation %.6g.\n', ...
            names{mode},seeds(s),bestconfig.layers,bestconfig.lambda,best);
    end
    ensembles(:,:,mode)=mean(predseeds,3);
    allrows=append(allrows,[names{mode} '_ensemble'],0,test,T,ensembles(:,:,mode),true(numel(test),1));
end
allrows=append(allrows,'training_mean',0,test,T,repmat(mean(T(train,:),1),numel(test),1),true(numel(test),1));
allrows=append(allrows,'physics_inverse',0,test,T,base(test,:),accepted(test));
allrows=append(allrows,'equilibrium_pretrained_nn',0,test,T,prior(test,:),true(numel(test),1));
% Frozen transfer check: both models/budgets were selected on a separate
% equilibrium validation set, before any full-servo test evaluation.
% These models used 5000 offline examples; do not compare training budgets
% as equal to the 72 full-servo-label direct networks above.
transfer_methods={'direct','first_moments'};
transfer=struct('method',{},'seed',{},'path',{});
for j=1:numel(transfer_methods)
    p=nan(numel(test),3,3);
    for s=1:3
        path=fullfile(cfg.root,'results','training_study_confirmatory_v1', ...
            sprintf('candidate_%s_budget1500_seed%d.mat',transfer_methods{j},730+s));
        frozen=load(path,'model');
        p(:,:,s)=bpil_training_study_predict(frozen.model,Xeq(test,:),zeros(numel(test),3));
        name=['equilibrium_5000_' transfer_methods{j}];
        allrows=append(allrows,name,730+s,test,T,p(:,:,s),true(numel(test),1));
        transfer(end+1)=struct('method',name,'seed',730+s,'path',path); %#ok<AGROW>
    end
    allrows=append(allrows,[name '_ensemble'],0,test,T,mean(p,3),true(numel(test),1));
end
copyfile(fullfile(cfg.root,'src','bpil_training_study_predict.m'),out);
writetable(struct2table(transfer),fullfile(out,'frozen_transfer_models.csv'));
R=struct2table(allrows);writetable(R,fullfile(out,'predictions.csv'));
writetable(struct2table(selections),fullfile(out,'validation_selection.csv'));
summary=summarize(R);writetable(summary,fullfile(out,'summary.csv'));
% Paired bootstrap over independent TEST OBJECTS, not time samples/seeds.
ensembles(:,:,7)=prior(test,:);
comparisons={1,2,'adding_power';4,2,'correct_vs_shuffled_power';2,5,'residual_vs_direct'; ...
    7,6,'servo_calibration_of_pretrained_nn'};
cirows=struct([]);rng(991122,'twister');B=2000;
for c=1:size(comparisons,1)
    a=comparisons{c,1};b=comparisons{c,2};
    d=1000*(abs(ensembles(:,:,a)-T(test,:))-abs(ensembles(:,:,b)-T(test,:)));
    draw=randi(numel(test),numel(test),B);means=zeros(B,3);
    for h=1:3,v=d(:,h);means(:,h)=mean(v(draw),1).';end
    for h=1:3
        q=prctile(means(:,h),[2.5 97.5]);
        row=struct('contrast',comparisons{c,3},'parameter',cfg.parameter_names{h}, ...
            'mean_error_reduction',mean(d(:,h)),'lower95',q(1),'upper95',q(2), ...
            'unit','g_or_mm','test_objects',numel(test));
        if isempty(cirows),cirows=row;else,cirows(end+1)=row;end %#ok<AGROW>
    end
end
writetable(struct2table(cirows),fullfile(out,'paired_bootstrap.csv'));
% Same held-out objects, paired distinct full motion records, physical inverse.
motion=struct([]);
for i=N+1:height(M)
    oid=M.object_id(i);
    for pair=[oid i]
        th=base(pair,:);e=1000*abs(th-T(oid,:));
        row=struct('object_id',oid,'probe_index',M.probe_index(pair), ...
            'physical_success',physical(pair),'usable',usable(pair),'accepted',accepted(pair), ...
            'mass_abs_error_g',e(1),'cx_abs_error_mm',e(2),'cz_abs_error_mm',e(3));
        if isempty(motion),motion=row;else,motion(end+1)=row;end %#ok<AGROW>
    end
end
writetable(struct2table(motion),fullfile(out,'paired_motion.csv'));
results=struct('cfg',cfg,'summary',summary,'predictions',R,'students',{students}, ...
    'frozen_transfer_models',transfer, ...
    'train_ids',train,'validation_ids',val,'test_ids',test,'scale',scale, ...
    'feature_scope','8 plateau summaries plus per-segment tracking and power statistics; not raw waveform network', ...
    'scope','Fixed nominal full-servo simulation, planar COM, fixed motion, no online learning');
save(fullfile(out,'results.mat'),'results','-v7.3');
plot_summary(out,summary);
fid=fopen(fullfile(out,'COMPLETE.txt'),'w');fprintf(fid,'Signal/training analysis complete %s\n',char(datetime('now')));fclose(fid);
disp(summary(summary.seed==0,:));fprintf('Analysis complete: %s\n',out);
end

function [model,info]=fit_validated(X,Y,Xv,Yv,layers,lambda,seed)
args={'LayerSizes',layers,'Activations','tanh','Standardize',true,'Lambda',lambda,'Verbose',0};
rng(seed,'twister');
model=fitrnet(X,Y,args{:},'IterationLimit',500, ...
    'ValidationData',{Xv,Yv},'ValidationPatience',20);
C=model.ConvergenceInfo;H=C.History;
if istable(H)
    [~,ix]=min(H.ValidationLoss);iteration=H.Iteration(ix);
else
    [~,ix]=min([H.ValidationLoss]);iteration=H(ix).Iteration;
end
info=struct('stop_iterations',C.Iterations,'chosen_iterations',iteration, ...
    'stopping_reason',char(C.ConvergenceCriterion));
% R2026a fitrnet already retains the minimum-validation-loss weights.
% ConvergenceInfo also includes subsequent patience iterations; its final
% history row is not necessarily the returned model's validation loss.
end

function [xq,xp]=features(obs,cfg)
% All q channels and known commands are available to both q and q+P models.
Fq=zeros(8,16);Fp=zeros(8,5);cycle=cfg.sim.move_s+cfg.sim.hold_s;
for j=1:8
    finish=cfg.sim.initial_hold_s+j*cycle;start=finish-cycle;
    ix=obs.t>start&obs.t<=finish+1e-9;pl=obs.t>=finish-.3&obs.t<=finish+1e-9;
    err=obs.q(ix,:)-obs.q_command(ix,:);tail=obs.q(pl,:)-obs.q_command(pl,:);
    Fq(j,:)=[mean(tail,1),sqrt(mean(err.^2,1)),mean(err,1),max(abs(err),[],1)];
    pv=obs.P(ix);Fp(j,:)=[mean(obs.P(pl)),std(obs.P(pl)),mean(pv),std(pv),max(pv)];
end
xq=Fq(:).'/0.01;xp=Fp(:).'/20;
end
function p=clip(p,b)
p=min(max(p,b(:,1).'),b(:,2).');
end
function rows=append(rows,name,seed,ids,T,p,a)
for k=1:numel(ids)
    i=ids(k);e=1000*(p(k,:)-T(i,:));
    r=struct('method',name,'seed',seed,'object_id',i,'accepted',a(k), ...
        'mass_true_kg',T(i,1),'cx_true_m',T(i,2),'cz_true_m',T(i,3), ...
        'mass_est_kg',p(k,1),'cx_est_m',p(k,2),'cz_est_m',p(k,3), ...
        'mass_error_g',e(1),'cx_error_mm',e(2),'cz_error_mm',e(3));
    if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
end
end
function S=summarize(T)
keys=unique(T(:,{'method','seed'}),'rows','stable');rows=struct([]);
for k=1:height(keys)
    ix=strcmp(T.method,keys.method{k})&T.seed==keys.seed(k);E=[T.mass_error_g(ix),T.cx_error_mm(ix),T.cz_error_mm(ix)];
    mae=mean(abs(E),1);rmse=sqrt(mean(E.^2,1));mx=max(abs(E),[],1);
    ae=mean(abs(E(logical(T.accepted(ix)),:)),1);
    r=struct('method',keys.method{k},'seed',keys.seed(k),'test_n',sum(ix), ...
        'accepted_n',sum(T.accepted(ix)),'mass_mae_g',mae(1),'cx_mae_mm',mae(2),'cz_mae_mm',mae(3), ...
        'mass_rmse_g',rmse(1),'cx_rmse_mm',rmse(2),'cz_rmse_mm',rmse(3), ...
        'mass_max_g',mx(1),'cx_max_mm',mx(2),'cz_max_mm',mx(3), ...
        'accepted_mass_mae_g',ae(1),'accepted_cx_mae_mm',ae(2),'accepted_cz_mae_mm',ae(3));
    if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
end
S=struct2table(rows);
end
function plot_summary(out,S)
S=S(S.seed==0,:);f=figure('Visible','off','Position',[100 100 1450 700]);
tiledlayout(1,3,'TileSpacing','compact');fields={'mass_mae_g','cx_mae_mm','cz_mae_mm'};
for j=1:3
    nexttile;barh(S.(fields{j}));yticks(1:height(S));
    if j==1,yticklabels(strrep(S.method,'_',' '));else,yticklabels({});end
    xlabel(strrep(fields{j},'_',' '));grid on;set(gca,'YDir','reverse');
end
sgtitle('Held-out full-servo objects: signal ablations and training methods');
exportgraphics(f,fullfile(out,'signal_comparison.png'),'Resolution',160);close(f);
end
