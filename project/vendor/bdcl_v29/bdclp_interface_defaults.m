function H = bdclp_interface_defaults()
%BDCLP_INTERFACE_DEFAULTS Raw RoArm-M2 wire interface; no hardware is opened.
% Wire angles = sign .* model angles + zero_offset_rad. All four mappings,
% mechanically safe limits and feedback semantics require local calibration.
H.schema = 'roarm_m2_position_interface_20hz_v2';
H.simulation_only = true;
H.calibrated = false;
H.calibration_id = '';
H.firmware_id = '';
H.ee_mode = 'unconfigured'; % wrist or gripper; four-R model requires wrist
H.long_rod_verified = false;
H.serial_port = '';
H.control_dt_s = .05;
H.startup_timeout_s = 3;
H.start_position_tolerance_rad = .05; % explicit pre-position acceptance
H.max_rx_queue = 256;
H.max_line_bytes = 4096;
H.poll_pause_s = .001;
H.required_torque_limit_register = [1000 1000 1000 1000];
H.allow_torque_limit_write = false;
H.nominal_sign = [1 1 1 1];
H.nominal_zero_offset_rad = [0 0 0 pi];
H.sign = nan(1,4);
H.zero_offset_rad = nan(1,4);
H.model_qmin_rad = nan(1,4);
H.model_qmax_rad = nan(1,4);
H.wire_qmin_rad = nan(1,4);
H.wire_qmax_rad = nan(1,4);
H.feedback_t_semantics = 'unconfigured';
% 'joint_angle' (stock EEMode=0), or 'wrist_tool_pitch' (audited EEMode=1).
H.position_source_verified = false;
H.clock_id = 'host_monotonic_seconds';
H.max_feedback_age_s = .080; % same position-age contract as C
H.max_power_age_s = .040; % independent power sampler age contract
H.request_timeout_s = .100; % missing reply timeout, not accepted sample age
H.max_acquisition_span_s = .050; % sequential read window, uncalibrated
H.speed_range_steps_s = [1 4096];
H.acc_range_100steps_s2 = [1 254];
H.baud_rate = 115200; % SDK default; throughput must be measured
H.feedback_request = sprintf('{"T":105}\n');
H.command_type = 102;
H.feedback_type = 1051;
H.protocol_source = 'https://github.com/waveshareteam/waveshare_roarm_sdk/blob/main/roarm_sdk/common.py';
H.firmware_source = 'https://github.com/waveshareteam/roarm_m2/blob/main/RoArm-M2_example/RoArm-M2_module.h';
H.audited_reference_firmware_commit = 'c6ccc5bda2eb92df2f0850d3e63cc42b81557f4f';
H.audited_reference_sdk_commit = 'd9893632aa7f5a9cb283136ab024faf3143ea7db';
end
