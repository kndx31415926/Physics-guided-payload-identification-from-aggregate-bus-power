function out=pgar_model_predict(bundle,obs)
%PGAR_MODEL_PREDICT Deploy the prespecified largest-budget residual ensemble.
% Reads observations only. theta stays NaN on an observation/teacher rejection;
% candidate_theta is an explicitly unauthenticated diagnostic, not an output
% to accept blindly. Acceptance is heuristic and is not an accuracy guarantee.
out=struct('theta',nan(1,3),'candidate_theta',nan(1,3), ...
    'seed_predictions',[],'accepted',false,'reasons',{{}},'teacher',[]);
assert(isstruct(bundle)&&strcmp(bundle.schema,'pgar_residual_bundle_v1'), ...
    'pgar:Bundle','Expected a PGAR residual model bundle.');
f=pgar_model_features(bundle.cfg,obs,bundle.scale,bundle.probe_id);
out.teacher=f.teacher;out.reasons=f.reasons;if ~f.usable,return,end
models=bundle.models;n=numel(models);pred=nan(n,3);B=bundle.cfg.ident.bounds;
for s=1:n
    learner=models{s};
    assert(strcmp(learner.selection.method,'physics_residual_nn')&& ...
        numel(learner.columns)==13,'pgar:Bundle','Invalid residual learner.');
    p=predict(learner.model,f.residual(:,learner.columns)).*bundle.scale+f.base;
    pred(s,:)=min(max(p,B(:,1).'),B(:,2).');
end
if ~all(isfinite(pred),'all'),out.reasons={'nonfinite_network_prediction'};return,end
out.seed_predictions=pred;out.candidate_theta=mean(pred,1);
out.accepted=f.teacher_accepted;if out.accepted,out.theta=out.candidate_theta;end
end
