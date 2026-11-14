function st = bdclp_servo_init(q,dq,C,model)
%BDCLP_SERVO_INIT No gravity feedforward or hidden settled-hold initialisation.
assert(isstruct(C) && isfield(C,'servo') && isstruct(C.servo), ...
    'bdclp:ServoConfig','C.servo is required.');
assert(isstruct(model) && isfield(model,'n') && model.n==4, ...
    'bdclp:ServoModel','A four-axis model is required.');
q = row4(q,'q'); dq = row4(dq,'dq');
st.schema = 'position_servo_state_v1';
st.q = q;
st.dq = dq;
st.q_target = q;
st.dq_target = zeros(1,4);
st.integral_tau_Nm = zeros(1,4);
st.energy_draw_J = 0;
st.braking_work_J = 0;
st.elapsed_s = 0;
st.initialization = 'integrator_zero_not_equilibrium; holding must be simulated';
end

function v = row4(v,name)
assert(isnumeric(v) && isreal(v) && isequal(size(v),[1 4]) && ...
    all(isfinite(v)), 'bdclp:ServoInput','%s must be a finite real 1x4 row.',name);
v=double(v);
end
