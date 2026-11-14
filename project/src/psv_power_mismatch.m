function delta=psv_power_mismatch(tau,condition)
% Generative sensor law only. Never called from an estimator.
assert(isnumeric(tau)&&size(tau,2)==4&&all(isfinite(tau),'all'),'psv:Torque','Expected finite N-by-4 simulated torque.');
delta=condition.abs_torque_W_per_Nm*sum(abs(tau),2)+condition.quartic_torque_W_per_Nm4*sum(tau.^4,2);
assert(all(isfinite(delta)&delta>=0),'psv:Power','Invalid extra draw.');
end
