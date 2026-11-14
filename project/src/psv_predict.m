function [M,F]=psv_predict(models,cfg,obs)
% This boundary accepts observations only; no truth or condition metadata.
F=struct('steady',psf_features(obs,models.spec.probe_id), ...
    'physics',pgar_model_features(cfg,obs,models.spec.scale,models.spec.probe_id));
M=psf_predict(models,F,cfg);
end
