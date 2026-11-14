function P = bdclp_port_power(q,dq,tau,C)
%BDCLP_PORT_POWER Empirical nonnegative power at the whole-arm DC input.
% This function does not account for where negative shaft work goes. It is
% not an energy-conserving DC circuit or proof of indefinite braking safety.
row4(q,'q'); dq=row4(dq,'dq'); tau=row4(tau,'tau');
assert(isstruct(C) && isfield(C,'power') && isstruct(C.power), ...
    'bdclp:PowerConfig','C.power is required.');
B=C.power;
assert(isfield(B,'schema') && strcmp(B.schema,'empirical_nonnegative_port_v1'), ...
    'bdclp:PowerSchema','Power model schema mismatch.');
assert(isnumeric(B.coefficients) && isreal(B.coefficients) && ...
    isequal(size(B.coefficients),[1 13]) && ...
    all(isfinite(B.coefficients)) && all(B.coefficients>=0), ...
    'bdclp:PowerCoefficients','Power coefficients must be a nonnegative finite 1x13 row.');
scalar_positive(B.Vin_V,'Vin_V');
scalar_positive(B.min_voltage_V,'min_voltage_V');
scalar_positive(B.max_voltage_V,'max_voltage_V');
scalar_positive(B.max_current_A,'max_current_A');
assert(B.min_voltage_V<B.max_voltage_V, ...
    'bdclp:PowerVoltageBounds','Voltage bounds must be ordered.');
shaft=tau.*dq;
x=[1,tau.^2,max(shaft,0),abs(dq)];
components=x.*B.coefficients;
assert(all(isfinite(x)) && all(isfinite(components)) && isfinite(sum(components)), ...
    'bdclp:PowerNumerics','Empirical power calculation overflowed.');
P=struct();
P.Pin_W=sum(components);
P.Pdraw_W=P.Pin_W;
P.Vin_V=double(B.Vin_V);
P.Iin_A=P.Pin_W/P.Vin_V;
P.features=x;
P.feature_schema='aux_tau2_positive_shaft_abs_speed_v1';
P.components_W=components;
P.P_aux_W=components(1);
P.P_hold_W=sum(components(2:5));
P.P_motoring_W=sum(components(6:9));
P.P_speed_W=sum(components(10:13));
P.P_shaft_W=sum(shaft);
P.P_braking_mechanical_W=sum(max(-shaft,0));
P.Preturn_W=0; % Predictor credit, not a measured zero-return claim.
P.current_limit_exceeded=P.Iin_A>B.max_current_A+1e-12;
P.voltage_out_of_range=P.Vin_V<B.min_voltage_V || P.Vin_V>B.max_voltage_V;
P.pass=~P.current_limit_exceeded && ~P.voltage_out_of_range;
P.reasons={};
if P.current_limit_exceeded, P.reasons{end+1}='source_current_exceeded'; end
if P.voltage_out_of_range, P.reasons{end+1}='supply_voltage_out_of_range'; end
P.schema=B.schema;
P.calibrated=isfield(B,'calibrated') && logical(B.calibrated);
P.energy_balance_verified=false;
P.thermal_safety_verified=false;
P.regen_observed=false;
end

function v=row4(v,name)
assert(isnumeric(v) && isreal(v) && isequal(size(v),[1 4]) && ...
    all(isfinite(v)), 'bdclp:PowerInput','%s must be a finite real 1x4 row.',name);
v=double(v);
end
function scalar_positive(v,name)
assert(isnumeric(v) && isreal(v) && isscalar(v) && isfinite(v) && v>0, ...
    'bdclp:PowerConfig','%s must be a positive finite scalar.',name);
end
