function out=bpil_hefting_predict(bundle,obs,eta)
%BPIL_HEFTING_PREDICT Apply the three-seed PGAR residual ensemble to hardware.
% Rejected observations retain NaN theta. candidate_theta is diagnostic only;
% neither finite predictions nor heuristic acceptance establish accuracy.
assert(isstruct(bundle)&&isscalar(bundle)&&isfield(bundle,'schema')&& ...
    strcmp(bundle.schema,'pgar_residual_bundle_v1'), ...
    'pgar:Bundle','Expected a PGAR residual model bundle.');
required={'cfg','scale','probe_id','models','power_coefficients'};
assert(all(isfield(bundle,required))&&iscell(bundle.models)&&numel(bundle.models)==3, ...
    'pgar:Bundle','Expected a complete three-seed residual model bundle.');
for s=1:3
    learner=bundle.models{s};
    assert(isstruct(learner)&&all(isfield(learner,{'model','selection','columns'}))&& ...
        isfield(learner.selection,'method')&& ...
        strcmp(learner.selection.method,'physics_residual_nn')&& ...
        valid_columns(learner.columns), ...
        'pgar:Bundle','Invalid thirteen-feature residual learner.');
end
if nargin<3||isempty(eta),eta=struct('coefficients',bundle.power_coefficients);end
assert(isstruct(eta)&&isscalar(eta)&&isfield(eta,'coefficients')&& ...
    isnumeric(eta.coefficients)&&isreal(eta.coefficients)&& ...
    numel(eta.coefficients)==13&&all(isfinite(eta.coefficients(:)))&& ...
    all(eta.coefficients(:)>=0), ...
    'pra:Calibration','Expected thirteen finite nonnegative coefficients.');
c=bundle.cfg;c.legacy.power.coefficients=reshape(double(eta.coefficients),1,[]);
f=bpil_hefting_features(c,obs,bundle.scale,bundle.probe_id);
out=struct('raw',nan(1,3),'clipped',nan(1,3),'candidate_theta',nan(1,3), ...
    'theta',nan(1,3),'accepted',false,'available',false,'bounds_hit',false, ...
    'seed_raw',nan(0,3),'seed_clipped',nan(0,3), ...
    'feature',f,'teacher',f.teacher,'reasons',{f.reasons});
if ~f.usable,return,end
[raw,clipped]=pra_online_model_prediction(bundle.models,f.residual,f.base, ...
    reshape(double(bundle.scale),1,[]),c.ident.bounds);
out.seed_raw=reshape(permute(raw,[3 2 1]),[],3);
out.seed_clipped=reshape(permute(clipped,[3 2 1]),[],3);
out.raw=mean(out.seed_raw,1);out.clipped=mean(out.seed_clipped,1);
out.candidate_theta=out.clipped;
out.available=all(isfinite(out.seed_raw),'all')&&all(isfinite(out.seed_clipped),'all');
out.bounds_hit=any(abs(out.seed_raw-out.seed_clipped)>1e-12,'all');
if ~out.available
    out.reasons=[out.reasons,{'nonfinite_network_prediction'}];return
end
out.accepted=f.teacher_accepted;
if out.accepted,out.theta=out.clipped;end
end

function pass=valid_columns(columns)
% Training stores a 13-element logical varying-feature mask. Numeric index
% selectors are also supported when they select distinct residual columns.
pass=false;
if islogical(columns)
    pass=isvector(columns)&&numel(columns)==13&&any(columns(:));
elseif isnumeric(columns)&&isreal(columns)&&isvector(columns)&&~isempty(columns)
    v=double(columns(:));pass=all(isfinite(v))&&all(v==fix(v))&& ...
        all(v>=1&v<=13)&&numel(unique(v))==numel(v);
end
end
