function [dx,D]=pix_rhs(t,x,command,model)
%PIX_RHS SI electrothermal/mechanical balance; never an estimator feature.
% x=[q(4);dq(4);current(4);integral_torque(4);temperature(4);ledger(8)].
% Ledger order: bus, auxiliary, bridge, copper, brake, shaft, friction, cooling.
S=model.spec;C=model.condition;q=x(1:4).';v=x(5:8).';i=x(9:12).';z=x(13:16).';T=x(17:20).';
err=reshape(command,1,4)-q;
request=(S.kp.*err-S.kd.*v).*C.gain_scale+z;
unclipped_current=request./S.K_Nm_per_A;
iref=min(S.current_limit_A,max(-S.current_limit_A,unclipped_current));
R=S.R25_ohm.*C.resistance_scale.*(1+C.alpha_per_K*(T-S.ambient_C));
assert(all(R>0)&&all(isfinite(R)),'pix:Resistance','Nonpositive winding resistance.');
% Local current loop uses the declared cold resistance; no gravity feedforward
% or unknown mass/COM enters the controller.
vrequest=S.R25_ohm.*iref+S.K_Vs_per_rad.*v+S.current_gain_ohm.*(iref-i);
bridge_voltage=min(S.voltage_V,max(-S.voltage_V,vrequest));
drop=C.bridge_drop_V.*tanh(i/.05)+C.bridge_resistance_ohm.*i;
motor_voltage=bridge_voltage-drop;
di=(motor_voltage-R.*i-S.K_Vs_per_rad.*v)./S.L_H;
tau=S.K_Nm_per_A.*i;
friction=(S.coulomb.*C.coulomb_scale+C.stribeck_Nm.*exp(-(v/S.stribeck_speed_rad_s).^2)).* ...
    tanh(v/S.friction_smoothing_rad_s)+S.viscous.*C.viscous_scale.*v;
acc=forwardDynamics(model.robot,q,v,tau-friction);
dz=S.ki.*C.gain_scale.*err;
% Compare against the actual limits, not request-K*(request/K): the latter
% can turn floating-point roundoff into a false saturation switching surface.
% Conditional anti-windup, only the controller state is bounded.
blocked=((unclipped_current>S.current_limit_A)&dz>0)| ...
    ((unclipped_current<-S.current_limit_A)&dz<0)| ...
    ((vrequest>S.voltage_V)&dz>0)|((vrequest<-S.voltage_V)&dz<0)| ...
    ((z>=S.integral_limit_Nm)&dz>0)|((z<=-S.integral_limit_Nm)&dz<0);
dz(blocked)=0;
copper=R.*i.^2;cooling=S.cooling_W_per_K.*(T-S.ambient_C);
dT=(copper-cooling)./S.heat_capacity_J_per_K;
bridge_loss=drop.*i;bridge_input=bridge_voltage.*i;
brake=sum(max(-bridge_input,0));
aux=S.auxiliary_W+C.auxiliary_offset_W+C.auxiliary_ripple_W*sin(2*pi*C.auxiliary_ripple_Hz*t+C.ripple_phase);
bus=aux+sum(max(bridge_input,0));shaft=sum(tau.*v);friction_loss=sum(friction.*v);
magnetic_rate=sum(S.L_H.*i.*di);
ledger=[bus aux sum(bridge_loss) sum(copper) brake shaft friction_loss sum(cooling)];
dx=[v(:);acc(:);di(:);dz(:);dT(:);ledger(:)];
if nargout>1
    D=struct('bus_W',bus,'auxiliary_W',aux,'bridge_loss_W',sum(bridge_loss), ...
        'copper_W',sum(copper),'brake_W',brake,'shaft_W',shaft,'friction_W',friction_loss, ...
        'cooling_W',sum(cooling),'magnetic_rate_W',magnetic_rate,'tau_Nm',tau, ...
        'current_A',i,'temperature_C',T,'resistance_ohm',R,'motor_voltage_V',motor_voltage, ...
        'bridge_voltage_V',bridge_voltage,'integral_torque_Nm',z, ...
        'energy_identity_residual_W',bus-aux-sum(bridge_loss)-sum(copper)-brake-shaft-magnetic_rate);
end
end
