function report=bpil_arm_preflight(H,plan,action)
%BPIL_ARM_PREFLIGHT Pure, fail-closed validation; never opens a device.
assert(isstruct(H)&&isscalar(H),'bpil:ArmProfile','Profile must be a scalar struct.');
assert(any(strcmp(action,{'inspect','trajectory'})),'bpil:ArmAction','Unknown action.');
report=struct('ready',false,'issues',{{}},'action',action,'motion_allowed',false, ...
    'control_period_s',.05,'sample_count',0,'duration_s',0,'packets',{{}}, ...
    'max_sample_speed_rad_s',zeros(1,4),'max_sample_acc_rad_s2',zeros(1,4));
try
    scalar(H.baud_rate,'baud_rate',true);scalar(H.request_timeout_s,'request_timeout_s',false);
    scalar(H.startup_timeout_s,'startup_timeout_s',false);scalar(H.max_feedback_age_s,'max_feedback_age_s',false);
    scalar(H.max_acquisition_span_s,'max_acquisition_span_s',false);
    scalar(H.max_rx_queue,'max_rx_queue',true);scalar(H.max_line_bytes,'max_line_bytes',true);
    scalar(H.max_rx_buffer_bytes,'max_rx_buffer_bytes',true);scalar(H.max_rx_bytes_per_poll,'max_rx_bytes_per_poll',true);
    scalar(H.max_tx_backlog_s,'max_tx_backlog_s',false);scalar(H.poll_pause_s,'poll_pause_s',false);
    assert(H.max_line_bytes<=H.max_rx_buffer_bytes&&H.max_rx_bytes_per_poll<=H.max_rx_buffer_bytes, ...
        'bpil:ArmProfile','Receive-buffer bounds are inconsistent.');
    assert(ischar(H.clock_id)&&~isempty(H.clock_id),'bpil:ArmProfile','A clock_id is required.');
    assert(abs(H.control_dt_s-.05)<1e-12,'bpil:ArmCadence','Expected 50-ms command/request cadence.');
    if strcmp(action,'inspect')
        assert(isempty(plan),'bpil:ArmInspectPlan','Read-only inspection cannot contain a motion plan.');
        report.ready=true;return
    end
    flags={'calibrated','long_rod_verified','position_source_verified','probe_envelope_verified','payload_fixture_verified'};
    for k=1:numel(flags)
        assert(isequal(H.(flags{k}),true),'bpil:ArmCalibration','Confirm local %s before motion.',flags{k});
    end
    assert(isequal(H.simulation_only,false)&&strcmp(H.ee_mode,'wrist'), ...
        'bpil:ArmCalibration','A locally calibrated wrist-mode profile is required.');
    assert(any(strcmp(H.feedback_t_semantics,{'joint_angle','wrist_tool_pitch'})), ...
        'bpil:ArmCalibration','Configure measured fourth-angle semantics.');
    validateattributes(H.required_torque_limit_register,{'numeric'},{'size',[1 4],'real','finite','integer','>=',1,'<=',1000});
    assert(~H.allow_torque_limit_write,'bpil:ArmTorqueWrite','This control interface does not change torque limits.');
    scalar(H.start_position_tolerance_rad,'start_position_tolerance_rad',false);
    validateattributes(H.max_joint_speed_rad_s,{'numeric'},{'size',[1 4],'real','finite','positive'});
    validateattributes(H.max_joint_acc_rad_s2,{'numeric'},{'size',[1 4],'real','finite','positive'});
    validateattributes(H.max_command_step_rad,{'numeric'},{'size',[1 4],'real','finite','positive'});
    validateattributes(H.command_speed,{'numeric'},{'scalar','integer','>=',1,'<=',4096});
    validateattributes(H.command_acc,{'numeric'},{'scalar','integer','>=',1,'<=',254});
    assert(isstruct(plan)&&isscalar(plan)&&all(isfield(plan,{'t','q'})), ...
        'bpil:ArmPlan','Supply a plan with t and q arrays.');
    validateattributes(plan.q,{'numeric'},{'2d','ncols',4,'nonempty','real','finite'});
    validateattributes(plan.t,{'numeric'},{'column','numel',size(plan.q,1),'real','finite','nonnegative'});
    assert(size(plan.q,1)<=1e6,'bpil:ArmPlanSize','Plan exceeds one million samples.');
    expected=(0:size(plan.q,1)-1)'*H.control_dt_s;
    assert(all(abs(plan.t-expected)<1e-9),'bpil:ArmPlanGrid','Plan starts at zero and uses exactly 50-ms spacing.');
    q=plan.q;step=diff(q);v=step/H.control_dt_s;
    acc=diff([zeros(1,4);v;zeros(1,4)])/H.control_dt_s;
    assert(all(abs(step)<=H.max_command_step_rad+1e-12,'all'),'bpil:ArmStep','A target jump exceeds the local bound.');
    assert(all(abs(v)<=H.max_joint_speed_rad_s+1e-12,'all'),'bpil:ArmSpeed','A planned joint speed exceeds the local bound.');
    assert(all(abs(acc)<=H.max_joint_acc_rad_s2+1e-12,'all'),'bpil:ArmAcceleration','A planned acceleration exceeds the local bound.');
    packets=cell(size(q,1),1);
    for k=1:size(q,1)
        packets{k}=bdclp_encode_command(struct('q',q(k,:),'speed',H.command_speed,'acc',H.command_acc),H,'hardware');
    end
    report.ready=true;report.motion_allowed=true;report.sample_count=size(q,1);
    report.duration_s=plan.t(end);report.packets=packets;
    if ~isempty(v),report.max_sample_speed_rad_s=max(abs(v),[],1);end
    report.max_sample_acc_rad_s2=max(abs(acc),[],1);
catch e
    report.issues={struct('identifier',e.identifier,'message',e.message)};
end
end
function scalar(x,name,integer)
attributes={'scalar','real','finite','positive'};
if integer,attributes{end+1}='integer';end
validateattributes(x,{'numeric'},attributes,mfilename,name);
end
