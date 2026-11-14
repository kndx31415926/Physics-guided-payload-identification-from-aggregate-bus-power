function [updated_eta,report] = bpil_calibrate_anchor(cfg,obs,eta)
%BPIL_CALIBRATE_ANCHOR Calibrate only identifiable empty-arm loss parameters.
% Default: auxiliary draw and one common axes 2:4 holding scale. Individual
% axis changes cannot be inferred from this two-parameter calibration.
% Explicit independently known zero mass is mandatory. Unknown-payload
% pseudo-labels must never be used to update loss and load simultaneously.
updated_eta=eta;
parameterization=setting(cfg,'anchor_model','common_scale_aux');
assert(any(strcmp(parameterization,{'common_scale_aux','per_axis'})), ...
    'bpil:AnchorModel','anchor_model must be common_scale_aux or per_axis.');
report=struct('accepted',false,'rmse_W',Inf,'validation_rmse_W',Inf, ...
    'baseline_validation_rmse_W',Inf,'condition',Inf,'reasons',{{}}, ...
    'coefficient_indices',[1 3 4 5],'parameterization',parameterization, ...
    'limitation',['Empty-arm observations validate the selected loss parameterization only; ', ...
    'common-scale calibration does not identify separate axis drift or certify payload identifiability.']);
if ~isfield(obs,'is_anchor')||~isequal(obs.is_anchor,true)|| ...
        ~isfield(obs,'known_mass_kg')||~isscalar(obs.known_mass_kg)||obs.known_mass_kg~=0
    report.reasons={'requires_explicit_known_empty_anchor'};return
end
assert(all(isfield(obs,{'plateau_q','plateau_P','plateau_sd_P','stationary'})), ...
    'bpil:Observations','Missing measured anchor observations.');
q=double(obs.plateau_q);p=double(obs.plateau_P(:));n=size(q,1);
assert(size(q,2)==4&&numel(p)==n,'bpil:Observations','Invalid anchor dimensions.');
sigma0=setting(cfg,'power_sigma_W',.04);sd=double(obs.plateau_sd_P(:));
if isscalar(sd),sd=repmat(sd,n,1);end
stationary=obs.stationary;if isscalar(stationary),stationary=repmat(stationary,n,1);end
stationary=stationary(:);
assert(numel(sd)==n&&numel(stationary)==n,'bpil:Observations','Invalid anchor lengths.');
keep=all(isfinite(q),2)&isfinite(p)&isfinite(sd)&sd>=0& ...
    isfinite(stationary)&stationary==1;
rows=find(keep);q=q(keep,:);p=p(keep);sd=max(sd(keep),sigma0);
if isempty(q),report.reasons={'insufficient_independent_anchor_poses'};return,end
[~,~,group]=unique(round(q/1e-8)*1e-8,'rows','stable');ng=max(group);
fraction=setting(cfg,'validation_fraction',.25);
assert(fraction>0&&fraction<1,'bpil:Split','Invalid validation fraction.');
held=unique(round(linspace(1,ng,max(1,round(ng*fraction)))));
valid=ismember(group,held);train=~valid;
report.train_rows=rows(train);report.validation_rows=rows(valid);
if numel(unique(group(train)))<setting(cfg,'anchor_min_train_poses',6)|| ...
        numel(unique(group(valid)))<setting(cfg,'anchor_min_validation_poses',2)
    report.reasons={'insufficient_independent_anchor_poses'};return
end
[g0,~]=bpil_static_design(cfg,q);indices=[1 3 4 5];
c=double(eta.coefficients(:).');
assert(numel(c)==13&&all(isfinite(c))&&all(c>=0),'bpil:PowerModel','Invalid coefficients.');
reference=double(cfg.legacy.power.coefficients(:).');
assert(numel(reference)==13&&all(isfinite(reference))&&all(reference(3:5)>0), ...
    'bpil:AnchorReference','Positive finite reference holding coefficients are required.');
fixed=c(2)*g0(:,1).^2;
if strcmp(parameterization,'common_scale_aux')
    A=[ones(size(q,1),1),sum(g0(:,2:4).^2.*reference(3:5),2)];
    initial=[c(1),mean(c(3:5)./reference(3:5))];
    lower=setting(cfg,'anchor_common_lower',[0 .3]);
    upper=setting(cfg,'anchor_common_upper',[6 2.5]);
    report.parameter_names={'aux_W','common_holding_scale'};
else
    A=[ones(size(q,1),1),g0(:,2:4).^2];initial=c(indices);
    lower=setting(cfg,'anchor_coefficient_lower',[0 .3*reference(3:5)]);
    upper=setting(cfg,'anchor_coefficient_upper',[6 2.5*reference(3:5)]);
    report.parameter_names={'aux_W','holding_axis2','holding_axis3','holding_axis4'};
end
np=size(A,2);lower=double(lower(:).');upper=double(upper(:).');
assert(numel(lower)==np&&numel(upper)==np&&all(isfinite(lower))&& ...
    all(isfinite(upper))&&all(lower>=0)&&all(upper>lower), ...
    'bpil:AnchorBounds','Expected finite increasing nonnegative calibration bounds.');
scale=max(abs(initial),1);Aw=A(train,:)./sd(train);
s=svd(Aw.*scale,0);s=s(:);s(end+1:np,1)=0;
tol=max(size(Aw))*eps(max([1;s]));
if s(np)>tol,report.condition=s(1)/s(np);end
report.scaled_singular_values=s;
report.parameter_bounds=[lower(:),upper(:)];
if s(np)<=tol||report.condition>setting(cfg,'anchor_max_condition',1e5)
    report.reasons={'anchor_coefficients_not_identifiable'};return
end
options=optimoptions('lsqlin','Display','off','OptimalityTolerance',1e-9);
[fit,~,~,flag]=lsqlin(Aw,(p(train)-fixed(train))./sd(train), ...
    [],[],[],[],lower(:),upper(:),min(max(initial,lower),upper).',options);
candidate=c;
if strcmp(parameterization,'common_scale_aux')
    candidate(1)=fit(1);candidate(3:5)=fit(2)*reference(3:5);
else
    candidate(indices)=fit;
end
pred=fixed+A*fit;
old=c(1)+fixed+sum(g0(:,2:4).^2.*c(3:5),2);
report.rmse_W=sqrt(mean((pred(train)-p(train)).^2));
report.validation_rmse_W=sqrt(mean((pred(valid)-p(valid)).^2));
report.baseline_validation_rmse_W=sqrt(mean((old(valid)-p(valid)).^2));
report.candidate_coefficients=candidate;report.exitflag=flag;
report.fitted_parameters=fit(:).';
maxrmse=setting(cfg,'anchor_max_validation_rmse_W',3*sigma0);
reasons={};
if flag<=0,reasons{end+1}='anchor_optimizer_not_converged';end
if report.rmse_W>setting(cfg,'anchor_max_fit_rmse_W',3*sigma0)
    reasons{end+1}='anchor_fit_residual_too_large';
end
if report.validation_rmse_W>maxrmse,reasons{end+1}='anchor_holdout_residual_too_large';end
if report.validation_rmse_W>report.baseline_validation_rmse_W+ ...
        setting(cfg,'anchor_allowed_holdout_degradation_W',.1*sigma0)
    reasons{end+1}='anchor_holdout_degraded';
end
report.reasons=reasons;report.accepted=isempty(reasons);
if report.accepted
    updated_eta.coefficients=candidate;
    updated_eta.anchor_calibrated=true;
    updated_eta.calibration_scope=['Known empty anchor; ',parameterization, ...
        '; no separate-axis drift or payload identifiability certificate.'];
end
end
function v=setting(cfg,name,fallback)
v=fallback;if isfield(cfg.ident,name),v=cfg.ident.(name);end
end
