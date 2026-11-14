function [obs,truth]=psv_simulate_probe(cfg,payload,probe,condition,seed,communication)
% Full servo generator with nominal estimator deliberately kept separate.
% Same mature rigidBodyTree/integrator; this is not an independent simulator.
% Added electrical loss is evaluated at the 100-Hz power sampling instants.
% As in the inherited plant, bus draw has no supply-sag feedback to torque.
plant=cfg;plant.sim.communication=communication;
p=plant.legacy.geometry.robot_params;
p.mass=p.mass.*condition.link_mass_scale;
p.I6_com=p.I6_com.*condition.link_mass_scale(:);
p.com_xyz(:,1)=p.com_xyz(:,1)+condition.link_com_x_offset_m(:);
plant.legacy.geometry.robot_params=p;
drift=struct('holding_scale',ones(1,4),'aux_offset_W',0, ...
    'friction_scale',condition.friction_scale,'gain_scale',condition.gain_scale);
[obs,truth]=bpil_simulate_probe(plant,payload,probe,drift,seed);
extra=psv_power_mismatch(truth.tau,condition);truth.nominal_electrical_P=truth.P;
truth.P=truth.P+extra;truth.added_electrical_P_W=extra;obs.P=obs.P+extra;
truth.psv_sampled_current_A=truth.P/cfg.legacy.power.Vin_V;
truth.psv_sampled_current_limit_exceeded=any(truth.psv_sampled_current_A>cfg.legacy.power.max_current_A+1e-12);
if truth.psv_sampled_current_limit_exceeded
    truth.physical_success=false;truth.success=false;truth.reasons{end+1}='added_loss_sampled_source_current_exceeded';
end
window=min(.3,cfg.sim.hold_s/2);
for j=1:size(probe.poses,1)
    finish=cfg.sim.initial_hold_s+j*(cfg.sim.move_s+cfg.sim.hold_s);
    ix=obs.t>=finish-window-1e-10&obs.t<=finish+1e-10;
    if sum(ix)>=max(10,round(window*80)),obs.plateau_P(j)=mean(obs.P(ix));obs.plateau_sd_P(j)=std(obs.P(ix));end
end
truth.psv_condition=condition;
truth.scope=['Full PID rigid-body servo with prespecified link/servo mismatch and a sampled alternative electrical-loss law. ', ...
    'No supply sag or new contact/backlash model; estimator receives observations only and keeps nominal calibration.'];
end
