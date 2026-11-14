function result=pnn_physics8(cfg,obs,eta)
%PNN_PHYSICS8 Full eight-pose physical inverse; no held-out-pose claim.
% Same nominal model, bounds, multistart, and sensitivity diagnostics as the
% six-pose teacher, but every observed plateau is included in this fit.
B=double(cfg.ident.bounds);span=(B(:,2)-B(:,1)).';lo=B(:,1).';hi=B(:,2).';
result=struct('theta',mean(B,2).','accepted',false,'rmse_W',Inf,'condition',Inf, ...
    'scope','All eight observed poses fit; no independent pose validation.', ...
    'reasons',{{}},'selected_exitflag',NaN,'scaled_singular_values',nan(3,1));
assert(isequal(size(obs.plateau_q),[8 4])&&numel(obs.plateau_P)==8&& ...
    numel(obs.plateau_sd_P)==8&&numel(obs.stationary)==8&&all(obs.stationary(:)==1), ...
    'pnn:Physics8Observation','Eight stationary measured poses are required.');
q=double(obs.plateau_q);p=double(obs.plateau_P(:));sd=max(double(obs.plateau_sd_P(:)),cfg.ident.power_sigma_W);
assert(all(isfinite([q p sd]),'all')&&all(sd>0),'pnn:Physics8Observation','Invalid measurements.');
[g0,Y]=bpil_static_design(cfg,q);coeff=double(eta.coefficients(:).');
assert(numel(coeff)==13&&all(isfinite(coeff))&&all(coeff>=0),'pnn:Physics8Calibration','Invalid calibration.');
starts=[mean(B,2).';lo+span.*[.15 .15 .15];lo+span.*[.85 .85 .85]; ...
    lo+span.*[.15 .85 .85];lo+span.*[.85 .15 .15];lo+span.*[.50 .15 .85];lo+span.*[.50 .85 .15]];
options=optimoptions('lsqnonlin','Display','off','SpecifyObjectiveGradient',true, ...
    'MaxIterations',300,'FunctionTolerance',1e-10,'StepTolerance',1e-10,'OptimalityTolerance',1e-9);
best=Inf;flags=nan(size(starts,1),1);costs=flags;
for k=1:size(starts,1)
    [t,cost,~,flag]=lsqnonlin(@residual,starts(k,:),lo,hi,options);flags(k)=flag;costs(k)=cost;
    if isfinite(cost)&&all(isfinite(t))&&cost<best,best=cost;result.theta=t(:).';result.selected_exitflag=flag;end
end
result.start_exitflags=flags;result.start_costs=costs;
if ~isfinite(best),result.reasons={'optimization_failed'};return,end
[prediction,J]=model(result.theta);result.rmse_W=sqrt(mean((prediction-p).^2));
S=svd(J.*span./sd,0);S=S(:);tol=max(size(J))*eps(max([1;S]));
result.scaled_singular_values=S;if S(3)>tol,result.condition=S(1)/S(3);end
reasons={};if result.selected_exitflag<=0,reasons{end+1}='optimizer_not_converged';end
if result.rmse_W>cfg.ident.max_fit_rmse_W,reasons{end+1}='fit_residual_too_large';end
if S(3)<1||S(3)<=tol,reasons{end+1}='insufficient_parameter_sensitivity';end
if result.condition>cfg.ident.max_condition,reasons{end+1}='ill_conditioned';end
result.reasons=reasons;result.accepted=isempty(reasons);result.prediction_W=prediction;
    function [r,J]=residual(t),[v,J]=model(t);r=(v-p)./sd;J=J./sd;end
    function [p0,J]=model(t)
        beta=[t(1) t(1)*t(2) t(1)*t(3)];tau=g0;
        for a=1:3,tau=tau+Y(:,:,a)*beta(a);end
        p0=coeff(1)+sum(tau.^2.*coeff(2:5),2);
        db=[1 0 0;t(2) t(1) 0;t(3) 0 t(1)];J=zeros(8,3);
        for a=1:3,d=zeros(8,4);for b=1:3,d=d+Y(:,:,b)*db(b,a);end;J(:,a)=2*sum(tau.*coeff(2:5).*d,2);end
    end
end
