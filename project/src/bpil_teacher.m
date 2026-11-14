function result = bpil_teacher(cfg,obs,eta,initial)
%BPIL_TEACHER Bounded multi-start inverse teacher with held-out pose checks.
% Reads only measured plateau q/P/SD/stationarity. No payload, task ID, or
% simulator state is accessed. The fitted model is NOT refit on holdout data.
if nargin<4,initial=[];end
B=double(cfg.ident.bounds);validate_bounds(B);
sigma0=setting(cfg,'power_sigma_W',.04);
assert(isscalar(sigma0)&&isfinite(sigma0)&&sigma0>0,'bpil:Noise','Invalid power sigma.');
result=struct('theta',mean(B,2).','accepted',false,'rmse_W',Inf, ...
    'validation_rmse_W',Inf,'condition',Inf,'confidence',0,'diagnostics',struct());
[q,p,sd,original]=measurements(obs,sigma0);
[train,valid,pose_count]=split_poses(q,setting(cfg,'validation_fraction',.25));
result.diagnostics=struct('used_measurement_rows',original,'train_rows',original(train), ...
    'validation_rows',original(valid),'unique_pose_count',pose_count, ...
    'confidence_scope','Heuristic diagnostic score, not probability or calibrated uncertainty.', ...
    'fit_uses_holdout',false,'reasons',{{}});
mintrain=setting(cfg,'min_train_poses',6);minvalid=setting(cfg,'min_validation_poses',2);
if num_unique(q(train,:))<mintrain||num_unique(q(valid,:))<minvalid
    result.diagnostics.reasons={'insufficient_independent_poses'};return
end
[g0,Y]=bpil_static_design(cfg,q);
coeff=double(eta.coefficients(:).');
assert(numel(coeff)==13&&all(isfinite(coeff))&&all(coeff>=0), ...
    'bpil:PowerModel','Invalid port-power coefficients.');
if isempty(initial),initial=mean(B,2).';end
validateattributes(initial,{'numeric'},{'vector','numel',3,'finite','real'});
lo=B(:,1).';hi=B(:,2).';span=hi-lo;
starts=[min(max(initial(:).',lo),hi);mean(B,2).'; ...
    lo+span.*[.15 .15 .15];lo+span.*[.85 .85 .85]; ...
    lo+span.*[.15 .85 .85];lo+span.*[.85 .15 .15]; ...
    lo+span.*[.50 .15 .85];lo+span.*[.50 .85 .15]];
starts=unique(starts,'rows','stable');best=Inf;bestexit=-Inf;
exitflags=nan(size(starts,1),1);costs=inf(size(starts,1),1);
options=optimoptions('lsqnonlin','Display','off','SpecifyObjectiveGradient',true, ...
    'MaxIterations',setting(cfg,'max_iterations',300),'FunctionTolerance',1e-10, ...
    'StepTolerance',1e-10,'OptimalityTolerance',1e-9);
for k=1:size(starts,1)
    [candidate,cost,~,flag]=lsqnonlin(@residual,starts(k,:),lo,hi,options);
    exitflags(k)=flag;costs(k)=cost;
    if isfinite(cost)&&all(isfinite(candidate))&&cost<best
        best=cost;result.theta=candidate(:).';bestexit=flag;
    end
end
result.diagnostics.start_exitflags=exitflags;result.diagnostics.start_costs=costs;
if ~isfinite(best),result.diagnostics.reasons={'optimization_failed'};return,end
[pred,Jac]=from_design(result.theta,g0,Y,coeff);
err=pred-p;
result.rmse_W=sqrt(mean(err(train).^2));
result.validation_rmse_W=sqrt(mean(err(valid).^2));
J=Jac(train,:).*span./sd(train);
s=svd(J,0);s=s(:);s(end+1:3,1)=0;
tol=max(size(J))*eps(max([1;s]));rankJ=sum(s>tol);
if s(3)>tol,result.condition=s(1)/s(3);end
maxfit=setting(cfg,'max_fit_rmse_W',3*sigma0);
maxvalid=setting(cfg,'max_validation_rmse_W',3*sigma0);
minsv=setting(cfg,'min_scaled_singular_value',1);
maxcond=setting(cfg,'max_condition',1e5);
reasons={};
if bestexit<=0,reasons{end+1}='optimizer_not_converged';end
if result.rmse_W>maxfit,reasons{end+1}='fit_residual_too_large';end
if result.validation_rmse_W>maxvalid,reasons{end+1}='heldout_residual_too_large';end
if rankJ<3||s(3)<minsv,reasons{end+1}='insufficient_parameter_sensitivity';end
if result.condition>maxcond,reasons{end+1}='ill_conditioned';end
result.accepted=isempty(reasons);
quality=exp(-.5*(result.validation_rmse_W/max(maxvalid,eps))^2);
result.confidence=double(result.accepted)*quality*s(3)/(s(3)+max(minsv,eps));
result.diagnostics.reasons=reasons;
result.diagnostics.prediction_W=pred;
result.diagnostics.residual_W=err;
result.diagnostics.sigma_W=sd;
result.diagnostics.scaled_singular_values=s;
result.diagnostics.sensitivity_rank=rankJ;
result.diagnostics.selected_exitflag=bestexit;
result.diagnostics.thresholds=struct('max_fit_rmse_W',maxfit, ...
    'max_validation_rmse_W',maxvalid,'min_scaled_singular_value',minsv,'max_condition',maxcond);
    function [r,jac]=residual(t)
        [v,jac]=from_design(t,g0(train,:),Y(train,:,:),coeff);
        r=(v-p(train))./sd(train);jac=jac./sd(train);
    end
end
function [p,J]=from_design(t,g0,Y,c)
h=[t(1),t(1)*t(2),t(1)*t(3)];tau=g0;
for k=1:3,tau=tau+Y(:,:,k)*h(k);end
p=c(1)+sum(tau.^2.*c(2:5),2);
dh=[1 0 0;t(2) t(1) 0;t(3) 0 t(1)];J=zeros(size(tau,1),3);
for k=1:3
    d=zeros(size(tau));
    for j=1:3,d=d+Y(:,:,j)*dh(j,k);end
    J(:,k)=2*sum(tau.*c(2:5).*d,2);
end
end
function validate_bounds(B)
assert(isequal(size(B),[3 2])&&all(isfinite(B(:)))&&all(B(:,2)>B(:,1))&&B(1,1)>0, ...
    'bpil:Bounds','Expected increasing 3-by-2 bounds and positive minimum mass.');
end
function [q,p,sd,original]=measurements(obs,sigma0)
assert(all(isfield(obs,{'plateau_q','plateau_P','plateau_sd_P','stationary'})), ...
    'bpil:Observations','Missing measured plateau observations.');
q=double(obs.plateau_q);p=double(obs.plateau_P(:));sd=double(obs.plateau_sd_P(:));
validateattributes(q,{'numeric'},{'2d','ncols',4,'real'});n=size(q,1);
if isscalar(sd),sd=repmat(sd,n,1);end
stationary=obs.stationary;if isscalar(stationary),stationary=repmat(stationary,n,1);end
stationary=stationary(:);
assert(numel(p)==n&&numel(sd)==n&&numel(stationary)==n, ...
    'bpil:Observations','Observation lengths differ.');
keep=all(isfinite(q),2)&isfinite(p)&isfinite(sd)&sd>=0& ...
    isfinite(stationary)&stationary==1;
original=find(keep);q=q(keep,:);p=p(keep);sd=max(sd(keep),sigma0);
end
function [train,valid,n]=split_poses(q,fraction)
assert(isscalar(fraction)&&fraction>0&&fraction<1,'bpil:Split','Invalid validation fraction.');
if isempty(q),train=false(0,1);valid=train;n=0;return,end
[~,~,group]=unique(round(q/1e-8)*1e-8,'rows','stable');n=max(group);
nv=max(1,round(n*fraction));held=unique(round(linspace(1,n,nv)));
valid=ismember(group,held);train=~valid;
end
function n=num_unique(q)
if isempty(q),n=0;else,n=size(unique(round(q/1e-8)*1e-8,'rows'),1);end
end
function v=setting(cfg,name,fallback)
v=fallback;if isfield(cfg.ident,name),v=cfg.ident.(name);end
end
