function H=bpil_arm_control_profile()
%BPIL_ARM_CONTROL_PROFILE Explicit local commissioning template, no I/O.
% Unknown mappings/ranges remain NaN. Never copy mock calibration to a robot.
H=bpil_hefting_hardware_profile();
H.control_interface_schema='bpil_arm_control_v1';
H.max_rx_buffer_bytes=16384;
H.max_rx_bytes_per_poll=4096;
H.max_tx_backlog_s=.030;
H.command_speed=NaN;
H.command_acc=NaN;
H.max_joint_speed_rad_s=nan(1,4);
H.max_joint_acc_rad_s2=nan(1,4);
H.max_command_step_rad=nan(1,4);
H.profile_scope=['Local model-to-wire mapping, installed wrist, joint limits, ' ...
    'motion limits and swept envelope must be independently checked. ' ...
    'Stock inspection is read-only and does not certify motion readiness.'];
end
