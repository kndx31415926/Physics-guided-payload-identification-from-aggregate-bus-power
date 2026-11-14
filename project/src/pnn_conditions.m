function condition=pnn_conditions(cfg,probe,family,seed,templates)
%PNN_CONDITIONS Frozen generative nuisance; never an estimator input.
% Independent factors scale each specified PSV departure by U(0.5,1.5).
if nargin<5,templates=psv_conditions(cfg,probe);end
names=["nominal","mechanical","electrical","combined"];index=find(names==string(family));
assert(isscalar(index),'pnn:Condition','Unknown condition family.');
condition=templates(index);condition.id=char(names(index));
s=RandStream('mt19937ar','Seed',double(seed));factor=@(n).5+rand(s,1,n);
if condition.mechanical
    condition.link_mass_scale=1+(condition.link_mass_scale-1).*factor(3);
    condition.link_com_x_offset_m=condition.link_com_x_offset_m.*factor(3);
    condition.friction_scale=1+(condition.friction_scale-1).*factor(4);
    condition.gain_scale=1+(condition.gain_scale-1).*factor(4);
end
if condition.electrical
    condition.abs_torque_W_per_Nm=condition.abs_torque_W_per_Nm*factor(1);
    condition.quartic_torque_W_per_Nm4=condition.quartic_torque_W_per_Nm4*factor(1);
end
condition.generator='Independent PSV departure multipliers Uniform(0.5,1.5); no measurement or fitted value.';
end
