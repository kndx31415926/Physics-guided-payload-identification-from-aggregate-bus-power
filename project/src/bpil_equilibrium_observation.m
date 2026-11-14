function [obs,truth]=bpil_equilibrium_observation(cfg,payload,probe,drift,seed)
% Fast IDEAL EQUILIBRIUM experiment; not the full position-servo simulation.
rng(seed,'twister');q=probe.poses;[g,Y]=bpil_static_design(cfg,q);
v=[payload.mass,payload.mass*payload.com(1),payload.mass*payload.com(3)];
tau=g;for k=1:3,tau=tau+Y(:,:,k)*v(k);end
coef=cfg.legacy.power.coefficients;
coef(2:5)=coef(2:5).*drift.holding_scale;coef(1)=coef(1)+drift.aux_offset_W;
p=coef(1)+sum(tau.^2.*coef(2:5),2);n=size(q,1);
obs=struct('plateau_q',q+cfg.sensor.position_std_rad*randn(size(q)), ...
    'plateau_P',p+cfg.sensor.power_std_W/sqrt(cfg.sensor.plateau_samples)*randn(n,1), ...
    'plateau_sd_P',cfg.sensor.power_std_W*ones(n,1), ...
    'stationary',true(n,1),'probe_id',probe.id);
truth=struct('success',true,'reasons',{{}},'payload',payload,'drift',drift, ...
    'scope','ideal_equilibrium_only_no_transient_or_friction_effect');
end
