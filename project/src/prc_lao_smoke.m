function evidence=prc_lao_smoke(outdir)
%PRC_LAO_SMOKE Synthetic development verification, not scientific evidence.
% Does not load any old or new held-out experiment objects.
if nargin<1,outdir='C:/new/results/prc_lao_development_smoke_v1';end
cfg=startup_bpil();maxNumCompThreads(1);rng(880021,'twister');
N=30;D=struct('object_id',(1:N).','split',[repmat("train",20,1);repmat("validation",5,1);repmat("test",5,1)], ...
    'theta',[.08+.14*rand(N,1),.05+.14*rand(N,1),-.018+.036*rand(N,1)], ...
    'state',zeros(N,8,4,4),'g0',zeros(N,8,4),'Y',zeros(N,8,4,3), ...
    'tau_label',zeros(N,8,4),'usable',true(N,1));
probes=bpil_probe_library(cfg);
for n=1:N
    q=probes(2).poses+.005*randn(8,4);[g0,Y]=bpil_static_design(cfg,q);
    th=D.theta(n,:);phi=[th(1) th(1)*th(2) th(1)*th(3)];tau=g0;
    for h=1:3,tau=tau+Y(:,:,h)*phi(h);end
    direction=2*(rand(8,4)>.5)-1;
    error=tau./[30 25 20 15]+.0005*direction;
    D.state(n,:,:,1)=q;D.state(n,:,:,2)=error;
    D.state(n,:,:,3)=double(direction>0);D.state(n,:,:,4)=double(direction<0);
    D.state(n,1,:,3:4)=0; % No approach motion for the initial pose.
    D.g0(n,:,:)=g0;D.Y(n,:,:,:)=Y;D.tau_label(n,:,:)=tau;
end
spec=struct('network_seeds',[830101 830102],'torque_epochs',3,'attention_epochs',2, ...
    'torque_batch',64,'attention_batch',8,'bounds',cfg.ident.bounds);
if ~exist(outdir,'dir'),mkdir(outdir);end
diary(fullfile(outdir,'smoke.log'));cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
[model,info]=prc_lao_train(D,1:20,21:25,spec,fullfile(outdir,'training'));
assert(info.complete&&all(info.last_gradient_norms>0,'all'));
full=prc_lao_predict(model,D,26:30,'attention');
stripped=rmfield(D,{'theta','tau_label','split'});
without_labels=prc_lao_predict(model,stripped,26:30,'attention');
assert(isequaln(full.theta_raw,without_labels.theta_raw),'Label removal changed predictions.');
testD=struct('state',D.state(26:30,:,:,:),'g0',D.g0(26:30,:,:), ...
    'Y',D.Y(26:30,:,:,:),'usable',true(5,1),'object_id',D.object_id(26:30));
separate=prc_lao_predict(model,testD,1:5,'attention');
assert(isequaln(full.theta_raw,separate.theta_raw),'Separate test array changed predictions.');
assert(max(abs(sum(full.weights,3)-1),[],'all')<1e-12,'Weights do not sum to one per pose.');
assert(all(full.rank==3,'all')&&all(isfinite(full.theta_raw),'all'));
% Compare the prediction implementation to the common independent raw WLS.
common_error=0;
for n=1:5
    for s=1:2
        w=reshape(full.weights(n,:,:,s),8,4);tau=reshape(full.tau(n,:,:,s),8,4);
        common=prc_wls(tau,reshape(testD.g0(n,:,:),8,4),reshape(testD.Y(n,:,:,:),8,4,3),w,cfg.ident.bounds);
        common_error=max(common_error,max(abs(common.raw_theta-full.theta_raw(n,:,s))));
    end
end
assert(common_error<1e-9,'Prediction differs from common unregularized WLS.');
% Direct finite-difference audit of the differentiable training solve.
Y=reshape(permute(double(D.Y(1,:,:,:)),[3 2 4 1]),32,3,1);
residual=reshape(permute(D.tau_label(1,:,:)-D.g0(1,:,:),[3 2 1]),32,1)+.003*randn(32,1);
w=.25*ones(32,1);sc=model.normalization.Y_column_scale;
[loss,grad]=dlfeval(@solve_gradient,Y,residual,dlarray(w),sc);
g=double(extractdata(grad));[~,j]=max(abs(g));step=1e-5;
wp=w;wm=w;wp(j)=wp(j)+step;wm(j)=wm(j)-step;
fp=sum(prc_lao_solve_dl(Y,residual,wp,sc,1e-10).^2,'all');
fm=sum(prc_lao_solve_dl(Y,residual,wm,sc,1e-10).^2,'all');
finite_difference=(fp-fm)/(2*step);
relative_error=abs(g(j)-finite_difference)/max(1e-12,abs(finite_difference));
assert(isfinite(double(extractdata(loss)))&&abs(g(j))>0&&relative_error<1e-4, ...
    'Differentiable WLS failed finite-difference check.');
[again,againinfo]=prc_lao_train(D,1:20,21:25,spec,fullfile(outdir,'training'));
resumed=prc_lao_predict(again,testD,1:5,'attention');
assert(againinfo.complete&&isequaln(resumed.theta_raw,separate.theta_raw),'Resume changed predictions.');
evidence=struct('scope','SYNTHETIC DEVELOPMENT ONLY; not formal test accuracy', ...
    'complete',true,'gradient_norms',info.last_gradient_norms, ...
    'differentiable_wls_gradient_relative_error',relative_error,'common_wls_max_error',common_error, ...
    'prediction_reads_no_labels',true,'separate_test_array',true,'resume_exact',true, ...
    'elapsed_training_s',info.elapsed_s,'checkpoint_resumes',againinfo.elapsed_s);
prc_lao_atomic_save(fullfile(outdir,'SMOKE_EVIDENCE.mat'),struct('evidence',evidence));
disp(evidence);fprintf('Lao adaptation synthetic smoke PASSED.\n');
end
function [loss,grad]=solve_gradient(Y,R,w,scale)
phi=prc_lao_solve_dl(Y,R,w,scale,1e-10);loss=sum(phi.^2,'all');grad=dlgradient(loss,w);
end
