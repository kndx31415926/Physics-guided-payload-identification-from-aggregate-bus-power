function B=bdclp_route_builder_defaults()
%BDCLP_ROUTE_BUILDER_DEFAULTS Independent copy of v28a16 planner choices.
% Provenance: spinn3d_params_block.m trajectory_builder block. No PB variable,
% old project folder, controller, torque limiter or runtime path is imported.
% 0.65 is nominal kinematic limit UTILIZATION, not a duration multiplier.
B.contract_id = ...
    'v28a16_bezier_dls_cosine_arc_quintic_port_r4';
B.ik_path_step_mm = 1.5;
B.bezier_min_step_mm = 0.2;
B.bezier_arclength_probe_count = 4000;
B.bezier_min_samples = 2;
B.bezier_spacing_mode = 'cosine_ease';
B.bezier_arc_interp_method = 'linear';
B.lateral_degenerate_norm_m = 1e-9;
B.lateral_normalization_floor_m = 1e-12;

B.dls_lambda = 0.02;
B.dls_w_ori = 0.02;
B.dls_qstep_deg = 2.0;
B.dls_pos_tol_m = 1e-4;
B.dls_inner_max = 80;
B.dls_linesearch_max = 12;
B.dls_posture_gain = 0.08;
B.dls_posture_progress_mode = 'quintic';
B.dls_retry_without_posture = true;
B.linesearch_initial_scale = 1.0;
B.linesearch_shrink_factor = 0.5;
B.linesearch_min_absolute_improvement_m = 1e-12;
B.linesearch_min_relative_improvement = 1e-7;

B.filter_mode = 'movmean_then_sgolay';
B.movmean_half_window = 1;
B.movmean_passes = 1;
B.movmean_min_samples = 3;
B.sgolay_order = 3;
B.sgolay_frame_length = 21;
B.sgolay_min_samples = 21;
B.sgolay_short_path_action = 'skip_sgolay';
B.endpoint_correction_mode = 'quintic';

B.reprojection_mode = 'independent_per_point';
B.reprojection_lambda = ...
    B.dls_lambda;
B.reprojection_w_ori = 0;
B.reprojection_qstep_deg = ...
    B.dls_qstep_deg;
B.reprojection_pos_tol_m = 1e-4;
B.reprojection_inner_max = 80;
B.reprojection_linesearch_max = ...
    B.dls_linesearch_max;
B.reprojection_posture_gain = 0;
B.raw_branch_jump_limit_deg = 45;

B.geometry_curve_mode = ...
    'open_uniform_clamped_cubic_bspline';
B.max_geometry_knots = 769;
B.geometry_candidate_knot_grid = ...
    [65 97 129 193 257 385 513 769];
B.cartesian_validation_step_mm = 0.5;
B.target_resample_interp_method = 'pchip';
B.geometry_smoothing_halfwindow_scale = 0.35;
B.geometry_smoothing_halfwindow_min = 1;
B.geometry_smoothing_passes = 2;
B.geometry_filter_mode = 'movmean';
B.geometry_control_interp_method = 'linear';
B.geometry_joint_limit_tolerance_rad = 1e-10;
B.geometry_endpoint_tolerance_rad = 1e-10;

B.time_progress_mode = 'quintic';
B.kinematic_time_margin = 0.65;
B.time_probe_min_count = 20001;
B.time_probe_per_spline_piece = 80;
B.time_probe_knot_half_step_factor = 0.25;
B.time_probe_inverse_interp_method = 'linear';
B.time_initial_safety_factor = 1.005;
B.time_refine_max_iterations = 8;
B.time_refine_ratio_tolerance = 1e-10;
B.time_refine_safety_factor = 1.002;
B.time_limit_tolerance = 1e-8;
B.allocation_full_range_safety_factor = 1.02;
B.allocation_fallback_span_min_rad = pi/2;
B.max_trajectory_duration_s = 30.0;

B.reference_sample_dt_s=.001;
B.max_trajectory_samples=ceil(B.max_trajectory_duration_s/B.reference_sample_dt_s)+1;
B.sgolay_implementation='fixed_polynomial_least_squares';
B.derivative_audit_scope='dense actual composed derivatives plus knot neighborhoods; not an analytic global certificate';
end
