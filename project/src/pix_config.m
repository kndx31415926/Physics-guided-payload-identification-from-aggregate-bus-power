function S=pix_config(cfg)
%PIX_CONFIG Prespecified cross-model test plant, never a fitted estimator.
% Same reduced geometry and MATLAB rigidBodyTree backend as the main study;
% independently constructed bodies, continuous dynamics, actuator and power.
% No parameter is inferred from unknown payload labels or predictor errors.
S.schema='pix_electrothermal_plant_v1';
S.scope=['Same-geometry cross-model simulation only; shared rigidBodyTree backend. ', ...
    'Not an identified ST3215, independent robot, hardware validation, or wear law.'];
S.dt_record_s=.01;S.command_period_s=.05;S.encoder_period_s=.05;
S.quantum_rad=2*pi/4096;S.delay_grid_s=.001;
S.rel_tol=2e-6;S.abs_tol=1e-8;S.max_step_s=.005;
S.ambient_C=25;S.voltage_V=12;S.maximum_source_current_A=5;
% Output-shaft-equivalent DC coordinates. Equal torque/back-EMF constants
% preserve power reciprocity in SI units. The shoulder is one equivalent
% actuator; the actual paired motors and their alignment are not simulated.
S.K_Nm_per_A=(2.941995/2.7)*ones(1,4);
S.K_Vs_per_rad=S.K_Nm_per_A;
% Match ONLY the declared cold static R/K^2 calibration, without labels,
% simulation episodes, regression, or fitting to frozen-model predictions.
S.R25_ohm=cfg.legacy.power.coefficients(2:5).*S.K_Nm_per_A.^2;
S.L_H=[.025 .018 .022 .012];
S.current_limit_A=cfg.legacy.servo.tau_stall_Nm./S.K_Nm_per_A;
S.current_gain_ohm=[3 3 3 3];
S.kp=cfg.legacy.servo.kp_Nm_per_rad;
S.ki=cfg.legacy.servo.ki_Nm_per_rad_s;
S.kd=cfg.legacy.servo.kd_Nm_s_per_rad;
S.integral_limit_Nm=cfg.legacy.servo.integral_limit_Nm;
S.viscous=cfg.legacy.servo.viscous_Nm_s_per_rad;
S.coulomb=cfg.legacy.servo.coulomb_Nm;
S.friction_smoothing_rad_s=.02;S.stribeck_speed_rad_s=.08;
S.heat_capacity_J_per_K=[12 24 12 8];
S.cooling_W_per_K=[.25 .5 .25 .18];
S.copper_alpha_per_K=.00393;
S.auxiliary_W=cfg.legacy.power.coefficients(1);
S.max_temperature_C=100;S.maximum_speed_rad_s=6;
S.severities=[0 .5 1];S.families={'mechanical','electrical','combined'};
S.mechanical_endpoint=struct('link_mass_departure',[.04 -.03 .05], ...
    'com_offset_m',[.0015 0 -.0005;-.001 0 .0008;.001 0 .0005], ...
    'viscous_departure',[.4 .6 .5 .4],'coulomb_departure',[.3 .5 .4 .3], ...
    'stribeck_Nm',[.025 .04 .025 .015],'gain_departure',[-.06 -.10 -.08 -.06]);
S.electrical_endpoint=struct('resistance_departure',[.06 .08 .05 .07], ...
    'initial_temperature_rise_K',[6 9 7 5],'bridge_drop_V',[.10 .14 .12 .08], ...
    'bridge_resistance_ohm',[.08 .06 .08 .08], ...
    'auxiliary_offset_W',.10,'auxiliary_ripple_W',.05,'auxiliary_ripple_Hz',.07);
S.parameter_status=['Explicit synthetic stress priors, not manufacturer motor ', ...
    'parameters. Severity is a prescribed interpolation, not service time.'];
S.energy_scope=['Ideal constant-voltage source; four non-regenerative bridges ', ...
    'dissipate each negative bridge input locally. Copper thermal states only; ', ...
    'no source sag, contact, backlash, gear compliance, paired-shoulder model, ', ...
    'collision certificate, or identified thermal protection.'];
S.sources=struct('dc_equations', ...
    'https://www.mathworks.com/help/simscape-electrical/ref/dcmotor.html', ...
    'rigid_body_dynamics','https://www.mathworks.com/help/robotics/ug/robot-dynamics.html', ...
    'inertia_origin','https://www.mathworks.com/matlabcentral/answers/1602190-why-the-robot-bodies-inertia-is-different-from-urdf#answer_848870');
S.source_note=['Equations follow standard DC motor and rigid-body balances; ', ...
    'implementation uses ode15s, not a claim to execute the Simscape block. ', ...
    'Geometry comes from the original declared reduced model, copied as values.'];
assert(all(S.R25_ohm>0)&&all(S.L_H>0),'pix:Config','Invalid circuit priors.');
end
