function conditions=psv_conditions(cfg,probe)
% Prespecified structural mismatch, normalized using a known nominal load.
% This is a sensitivity model, not an identified real actuator-loss law.
theta=[.15 .12 0];payload=struct('mass',theta(1),'com',[theta(2) 0 theta(3)]);
[model,~]=bpil_make_plant(cfg,payload);tau=zeros(size(probe.poses));
for k=1:size(tau,1),tau(k,:)=gravityTorque(model.robot,probe.poses(k,:));end
p=bpil_predict_power(cfg,probe.poses,theta,struct('coefficients',cfg.legacy.power.coefficients));
target=.02*mean(p);alpha=.5*target/mean(sum(abs(tau),2));beta=.5*target/mean(sum(tau.^4,2));
base=struct('id','nominal','mechanical',false,'electrical',false, ...
    'link_mass_scale',[1 1 1],'link_com_x_offset_m',[0 0 0], ...
    'friction_scale',ones(1,4),'gain_scale',ones(1,4), ...
    'abs_torque_W_per_Nm',0,'quartic_torque_W_per_Nm4',0, ...
    'loss_reference_theta',theta,'loss_reference_mean_P_W',mean(p), ...
    'loss_reference_extra_fraction',.02,'loss_reference_target_extra_W',target);
conditions=repmat(base,1,4);conditions(2).id='mechanical_mismatch';conditions(3).id='electrical_mismatch';conditions(4).id='combined_mismatch';
for k=[2 4]
    conditions(k).mechanical=true;conditions(k).link_mass_scale=[1.025 .98 1.03];
    conditions(k).link_com_x_offset_m=[.001 -.001 .0015];
    conditions(k).friction_scale=[1.15 1.35 1.25 1.4];conditions(k).gain_scale=[.98 .94 .96 .92];
end
for k=[3 4]
    conditions(k).electrical=true;conditions(k).abs_torque_W_per_Nm=alpha;conditions(k).quartic_torque_W_per_Nm4=beta;
end
end
