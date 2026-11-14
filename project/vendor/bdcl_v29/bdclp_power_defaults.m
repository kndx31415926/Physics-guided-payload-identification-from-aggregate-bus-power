function P = bdclp_power_defaults()
%BDCLP_POWER_DEFAULTS Nonnegative empirical whole-arm DC input predictor.
% All coefficients are nominal and must be fitted to measured port data.
P.schema = 'empirical_nonnegative_port_v1';
P.feature_schema = 'aux_tau2_positive_shaft_abs_speed_v1';
P.feature_names = {'aux_W','copper_axis1','copper_axis2','copper_axis3', ...
    'copper_axis4','motoring_axis1','motoring_axis2','motoring_axis3', ...
    'motoring_axis4','speed_axis1','speed_axis2','speed_axis3','speed_axis4'};
P.calibrated = false;
P.fitted = false;
% R/K^2 only seeds empirical hold coefficients from nominal stall endpoints.
% It does not identify winding resistance, a circuit topology or efficiency.
hold_seed = (12/2.7) / (2.941995/2.7)^2;
P.coefficients = [2, hold_seed./[1 2 1 1], ones(1,4)/0.75, 0.08*ones(1,4)];
P.Vin_V = 12;
P.min_voltage_V = 7;
P.max_voltage_V = 12.6;
P.max_current_A = 5;
P.soft_budget_W = 12;
P.filter_tau_s = 0.05;
P.scope = ['Empirical whole-arm DC-input consumption prediction, without ', ...
    'a transient source/capacitor/regen/thermal circuit. Negative shaft ', ...
    'work is diagnostic only: its physical destination is not modelled.'];
P.regen_scope = ['No recovery credit in this predictor; this is not evidence ', ...
    'that the physical arm has zero transient regeneration or sharing.'];
P.energy_balance_verified = false;
P.thermal_safety_verified = false;
P.limit_scope = ['Nominal 12-V / 5-A supply and documented whole-arm voltage ', ...
    'range; no identified current-limit, foldback or shutdown dynamics.'];
end
