function [next,D] = bdclp_servo_step(st,cmd,model,C,dt)
%BDCLP_SERVO_STEP Local position PID followed by rigid-body dynamics.
% An implicit dynamics root is solved, never an alternative safe command.
% The applied torque depends only on local servo variables; M and bias enter
% the plant equation, never the control law. No position/voltage projection.
S=C.servo; validate_inputs(st,cmd,model,S,dt);
q=st.q; v=st.dq;
rad_per_step=2*pi/S.command_steps_per_turn;
profile=bdclp_reference_profile(st.q_target,st.dq_target,cmd.q, ...
    cmd.speed*rad_per_step*ones(1,4), ...
    cmd.acc*100*rad_per_step*ones(1,4),dt);
ref=profile.q_end;refv=profile.v_end;
refmid=profile.q_mid;refvmid=profile.v_mid;
M=double(model.mass(q)); h=double(model.bias(q,v));
assert(isequal(size(M),[4 4]) && isreal(M) && all(isfinite(M(:))) && ...
    norm(M-M.','fro')<=1e-10*max(1,norm(M,'fro')), ...
    'bdclp:DynamicsMass','Mass matrix must be finite, real and symmetric.');
[~,chol_flag]=chol(M);
assert(chol_flag==0,'bdclp:DynamicsMass','Mass matrix must be positive definite.');
h=row4(h,'model.bias');
vn=v; converged=false; residual=Inf;
for it=1:S.solver_max_iterations
    [tau,requested,friction,dtau_dvn,dfric_dvn]=local_torque( ...
        q,v,vn,refmid,refvmid,st.integral_tau_Nm,S,dt);
    r=(M*((vn-v)/dt).').'+h+friction-tau;
    residual=norm(r,inf);
    if residual<=S.solver_tolerance_Nm, converged=true; break; end
    J=M/dt+diag(dfric_dvn-dtau_dvn);
    vn=vn-(J\r.').';
    if any(~isfinite(vn)), break; end
end
% Re-evaluate the final iterate; convergence on the last update is accepted.
[tau,requested,friction]=local_torque( ...
    q,v,vn,refmid,refvmid,st.integral_tau_Nm,S,dt);
residual=norm((M*((vn-v)/dt).').'+h+friction-tau,inf);
converged=converged || (isfinite(residual) && residual<=S.solver_tolerance_Nm);
vmid=0.5*(v+vn); qn=q+dt*vmid;
D=struct('tau',tau,'ddq',(vn-v)/dt,'dq_mid',vmid, ...
    'Pin_W',NaN,'Pdraw_W',NaN,'Vin_V',C.power.Vin_V,'Iin_A',NaN, ...
    'pass',false,'reasons',{{}},'solver_converged',converged, ...
    'solver_iterations',it,'solver_residual_Nm',residual, ...
    'tau_requested',requested,'local_saturation',abs(tau-requested)>1e-10);
D.reference=profile;
next=st;
if ~converged || any(~isfinite([qn vn tau]))
    D.reasons={'local_dynamics_solver_failed'};
    return;
end
next.q=qn; next.dq=vn;
next.q_target=ref; next.dq_target=refv;
% Conditional local antiwindup. Only the integral state is bounded; neither
% actual position nor the input command is projected into a safe set.
error_mid=refmid-(q+0.5*dt*vmid);
increment=dt*S.ki_Nm_per_rad_s.*error_mid;
outward=(requested-tau).*increment>0;
increment(outward)=0;
next.integral_tau_Nm=min(S.integral_limit_Nm, ...
    max(-S.integral_limit_Nm,st.integral_tau_Nm+increment));
P=bdclp_port_power(q+0.5*dt*vmid,vmid,tau,C);
D.Pin_W=P.Pin_W; D.Pdraw_W=P.Pdraw_W; D.Vin_V=P.Vin_V; D.Iin_A=P.Iin_A;
D.power=P;
D.energy_increment_J=dt*P.Pdraw_W;
D.braking_work_increment_J=dt*P.P_braking_mechanical_W;
next.energy_draw_J=st.energy_draw_J+D.energy_increment_J;
next.braking_work_J=st.braking_work_J+D.braking_work_increment_J;
next.elapsed_s=st.elapsed_s+dt;
% A midpoint sample lowers the chance of missing an excursion/collision
% between endpoints. This constant-acceleration interpolant is an audit
% sample, not a continuous collision certificate or a state projection.
q_half=q+0.5*dt*v+0.125*dt*(vn-v);
start_audit=model.audit(q,v); mid_audit=model.audit(q_half,vmid);
end_audit=model.audit(qn,vn);
assert(isstruct(start_audit) && isfield(start_audit,'pass') && ...
    isfield(start_audit,'reasons') && iscell(start_audit.reasons) && ...
    isstruct(mid_audit) && isfield(mid_audit,'pass') && ...
    isfield(mid_audit,'reasons') && iscell(mid_audit.reasons) && ...
    isstruct(end_audit) && isfield(end_audit,'pass') && ...
    isfield(end_audit,'reasons') && iscell(end_audit.reasons), ...
    'bdclp:ModelAudit','model.audit must return pass and cell reasons.');
D.start_audit=start_audit; D.mid_audit=mid_audit; D.end_audit=end_audit;
D.audit_scope='start_mid_end_samples_not_continuous_collision_certificate';
D.pass=logical(P.pass && start_audit.pass && mid_audit.pass && end_audit.pass);
D.reasons=[P.reasons(:).',start_audit.reasons(:).', ...
    mid_audit.reasons(:).',end_audit.reasons(:).'];
if ~D.pass && isempty(D.reasons), D.reasons={'model_audit_failed'}; end
end

function [tau,u,f,du,dfric]=local_torque(q,v,vn,ref,refv,integral,S,dt)
vm=0.5*(v+vn); qm=q+0.5*dt*vm;
u=S.kp_Nm_per_rad.*(ref-qm)+S.kd_Nm_s_per_rad.*(refv-vm)+integral;
% Nominal motoring derating, full nominal braking capability. This is a
% static actuator envelope, not an identified winding-current controller.
capability=S.tau_stall_Nm.*(S.torque_limit_register/1000);
upper=capability.*max(1-max(vm,0)./S.omega_no_load_rad_s,0);
lower=-capability.*max(1-max(-vm,0)./S.omega_no_load_rad_s,0);
tau=min(upper,max(lower,u));
du=-0.25*dt*S.kp_Nm_per_rad-0.5*S.kd_Nm_s_per_rad;
low=u<lower; high=u>upper;
du(low)=0; du(high)=0;
active_hi=high & vm>0 & vm<S.omega_no_load_rad_s;
active_lo=low & vm<0 & vm>-S.omega_no_load_rad_s;
idx=active_hi | active_lo;
du(idx)=-0.5*capability(idx)./S.omega_no_load_rad_s(idx);
z=tanh(vm/S.friction_smoothing_rad_s);
f=S.viscous_Nm_s_per_rad.*vm+S.coulomb_Nm.*z;
dfric=0.5*S.viscous_Nm_s_per_rad+ ...
    0.5*S.coulomb_Nm/S.friction_smoothing_rad_s.*(1-z.^2);
end

function validate_inputs(st,cmd,model,S,dt)
assert(isstruct(st) && isstruct(cmd) && isstruct(model) && isstruct(S), ...
    'bdclp:ServoInput','State, command, model and servo config must be structs.');
row4(st.q,'st.q'); row4(st.dq,'st.dq'); row4(st.q_target,'st.q_target');
row4(st.dq_target,'st.dq_target'); row4(st.integral_tau_Nm,'st.integral_tau_Nm');
row4(cmd.q,'cmd.q');
limits=row4(S.torque_limit_register,'torque_limit_register');
assert(all(limits>=0 & limits<=1000 & limits==fix(limits)), ...
    'bdclp:ServoConfig','Torque-limit settings must be integers 0..1000.');
assert(integer_between(cmd.speed,1,4096) && integer_between(cmd.acc,1,254), ...
    'bdclp:ServoCommand','speed must be integer 1..4096; acc integer 1..254.');
assert(isfield(cmd,'issued_t') && isscalar(cmd.issued_t) && ...
    isfinite(cmd.issued_t) && cmd.issued_t>=0 && ...
    isfield(cmd,'seq') && integer_between(cmd.seq,0,flintmax), ...
    'bdclp:ServoCommand','Command timestamp and sequence are invalid.');
assert(isfield(model,'n') && model.n==4 && isa(model.mass,'function_handle') && ...
    isa(model.bias,'function_handle') && isa(model.audit,'function_handle'), ...
    'bdclp:ServoModel','Four-axis model mass/bias/audit functions are required.');
nonnegative={'kp_Nm_per_rad','ki_Nm_per_rad_s','kd_Nm_s_per_rad', ...
    'viscous_Nm_s_per_rad','coulomb_Nm'};
positive={'tau_stall_Nm','integral_limit_Nm','omega_no_load_rad_s'};
for j=1:numel(nonnegative)
    a=row4(S.(nonnegative{j}),nonnegative{j});
    assert(all(a>=0),'bdclp:ServoConfig','Servo gains/losses must be nonnegative.');
end
for j=1:numel(positive)
    a=row4(S.(positive{j}),positive{j});
    assert(all(a>0),'bdclp:ServoConfig','Servo capability values must be positive.');
end
scalars={'command_steps_per_turn','friction_smoothing_rad_s', ...
    'solver_tolerance_Nm','max_step_s'};
for j=1:numel(scalars)
    a=S.(scalars{j});
    assert(isnumeric(a) && isreal(a) && isscalar(a) && isfinite(a) && a>0, ...
        'bdclp:ServoConfig','Servo scalar %s must be positive finite.',scalars{j});
end
assert(integer_between(S.solver_max_iterations,1,1000), ...
    'bdclp:ServoConfig','Invalid solver iteration count.');
assert(isnumeric(dt) && isreal(dt) && isscalar(dt) && isfinite(dt) && ...
    dt>0 && dt<=S.max_step_s*(1+1e-12), ...
    'bdclp:ServoStep','Step must be positive and no greater than max_step_s.');
for name={'energy_draw_J','braking_work_J','elapsed_s'}
    a=st.(name{1});
    assert(isnumeric(a) && isreal(a) && isscalar(a) && isfinite(a) && a>=0, ...
        'bdclp:ServoState','Invalid accumulated state %s.',name{1});
end
end
function v=row4(v,name)
assert(isnumeric(v) && isreal(v) && isequal(size(v),[1 4]) && ...
    all(isfinite(v)), 'bdclp:ServoInput','%s must be a finite real 1x4 row.',name);
v=double(v);
end
function ok=integer_between(v,lo,hi)
ok=isnumeric(v) && isreal(v) && isscalar(v) && isfinite(v) && ...
    v==floor(v) && v>=lo && v<=hi;
end
