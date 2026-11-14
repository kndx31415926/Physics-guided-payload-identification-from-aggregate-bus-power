function f=pra_online_features(state,obs,eta)
% Observation-only PGAR features under the supplied estimated calibration.
assert(isstruct(eta)&&isfield(eta,'coefficients')&&numel(eta.coefficients)==13&& ...
    all(isfinite(eta.coefficients))&&all(eta.coefficients>=0), ...
    'pra:Calibration','Expected thirteen finite nonnegative coefficients.');
c=state.cfg;c.legacy.power.coefficients=reshape(double(eta.coefficients),1,[]);
if isstruct(obs)&&isscalar(obs)&&isfield(obs,'schema')&& ...
        isequal(string(obs.schema),"bpil_hardware_observation_v1")
    f=bpil_hefting_features(c,obs,state.scale,state.probe_id);
else
    f=pgar_model_features(c,obs,state.scale,state.probe_id);
end
end
