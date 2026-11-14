function S = bdclp_servo_defaults()
%BDCLP_SERVO_DEFAULTS Unidentified local position-servo assumptions.
% These gains/limits do not describe identified ST3215 firmware. Joint two
% has two nominal parallel servos; synchronisation error is not represented.
S.schema = 'nominal_local_position_pid_v2';
S.calibrated = false;
S.scope = ['Finite-bandwidth local PID and command-profile approximation; ', ...
    'not identified firmware, direct torque control, or a safety controller.'];
S.command_steps_per_turn = 4096;
S.kp_Nm_per_rad = [30 50 35 15];
S.ki_Nm_per_rad_s = [45 75 52.5 22.5];
S.kd_Nm_s_per_rad = [0.8 1.3 0.7 0.18];
S.tau_stall_Nm = (30 * 0.0980665) * [1 2 1 1];
S.torque_limit_register = [1000 1000 1000 1000];
S.torque_limit_scope = ['Explicit research configuration, including wrist; ', ...
    'not factory boot defaults. Hardware initialization must set the same ', ...
    'values (both shoulder servos), with verification status recorded. ', ...
    'Linear scaling of capability by register/1000 is an unidentified approximation.'];
S.integral_limit_Nm = S.tau_stall_Nm;
S.omega_no_load_rad_s = (45 * 2*pi/60) * ones(1,4);
S.reference_profile = 'analytic_triangular_trapezoidal_with_braking_overshoot_v1';
S.reference_limit_scope = ['Internal reference uses only the commanded SDK ', ...
    'speed/acceleration values; no additional invented firmware cap. ', ...
    'These are reference settings, not actual joint acceleration guarantees.'];
S.viscous_Nm_s_per_rad = [0.005 0.008 0.006 0.004];
S.coulomb_Nm = [0.030 0.050 0.040 0.030];
S.friction_smoothing_rad_s = 0.02;
S.solver_max_iterations = 30;
S.solver_tolerance_Nm = 1e-9;
S.max_step_s = 0.001;
S.protection_scope = ['No firmware overload timer, winding thermal state, ', ...
    'or regenerative braking circuit is identified or simulated.'];
S.integration = ['Implicit midpoint local PID/friction with rigid-body M ', ...
    'and bias frozen at the start of each integration step; convergence ', ...
    'must be checked for the study trajectories. No state projection.'];
end
