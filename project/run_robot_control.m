function R=run_robot_control(opts)
%RUN_ROBOT_CONTROL Independent RoArm commissioning; default opens nothing.
% No model, power meter or training dependency. Never auto-homes the robot.
if nargin<1,opts=struct();end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
allowed={'mode','action','hardware','profile_file','plan','transport','output_file', ...
    'enable_hardware','max_time_s','stop_requested','max_io_overrun_s', ...
    'max_tracking_error_rad','final_tolerance_rad','final_hold_s'};
assert(isstruct(opts)&&isscalar(opts)&&all(ismember(fieldnames(opts),allowed)), ...
    'bpil:ArmOptions','Unknown robot-control option.');
mode=char(string(get(opts,'mode','dry_run')));action=char(string(get(opts,'action','inspect')));
assert(any(strcmp(mode,{'dry_run','mock','hardware'})),'bpil:ArmMode','Unknown mode.');
assert(any(strcmp(action,{'ports','inspect','trajectory'})),'bpil:ArmAction','Unknown action.');
if strcmp(action,'ports')
    R=struct('schema','bpil_arm_ports_v1','ports',serialportlist('available'), ...
        'hardware_opened',false,'motion_commands_sent',0);return
end
assert(~(isfield(opts,'hardware')&&isfield(opts,'profile_file')),'bpil:ArmProfile','Use hardware or profile_file, not both.');
H=get(opts,'hardware',bpil_arm_control_profile());
if isfield(opts,'profile_file')
    raw=jsondecode(fileread(opts.profile_file));assert(isstruct(raw)&&isscalar(raw),'bpil:ArmProfile','Profile JSON must contain one object.');
    fields=fieldnames(raw);template=bpil_arm_control_profile();
    assert(all(ismember(fields,fieldnames(template))),'bpil:ArmProfile','Unknown profile field.');
    for k=1:numel(fields),H.(fields{k})=raw.(fields{k});end
    % jsondecode may return numeric JSON vectors as columns.
    for f={'sign','zero_offset_rad','model_qmin_rad','model_qmax_rad', ...
            'wire_qmin_rad','wire_qmax_rad','nominal_sign','nominal_zero_offset_rad', ...
            'required_torque_limit_register','max_joint_speed_rad_s', ...
            'max_joint_acc_rad_s2','max_command_step_rad','speed_range_steps_s','acc_range_100steps_s2'}
        if isnumeric(H.(f{1}))&&isvector(H.(f{1})),H.(f{1})=reshape(H.(f{1}),1,[]);end
    end
end
plan=get(opts,'plan',[]);preflight=bpil_arm_preflight(H,plan,action);
O=struct('action',action,'max_time_s',10,'stop_requested',@()false,'max_io_overrun_s',.1, ...
    'max_tracking_error_rad',.20,'final_tolerance_rad',.01,'final_hold_s',.20, ...
    'speed',H.command_speed,'acc',H.command_acc);
if strcmp(action,'trajectory')&&preflight.ready,O.max_time_s=max(10,2*preflight.duration_s+5);end
for f={'max_time_s','stop_requested','max_io_overrun_s','max_tracking_error_rad','final_tolerance_rad','final_hold_s'}
    if isfield(opts,f{1}),O.(f{1})=opts.(f{1});end
end
% Invalid callback/time limits must fail before opening a device.
for f={'max_time_s','max_io_overrun_s','max_tracking_error_rad','final_tolerance_rad','final_hold_s'}
    validateattributes(O.(f{1}),{'numeric'},{'scalar','real','finite','positive'});
end
assert(isa(O.stop_requested,'function_handle'),'bpil:ArmStop','stop_requested must be a function handle.');
file=get(opts,'output_file','');
if isempty(file)&&strcmp(mode,'hardware')
    folder=fullfile(root,'results','hardware_control');
    file=fullfile(folder,['control_' char(datetime('now','Format','yyyyMMdd_HHmmss')) '_' char(java.util.UUID.randomUUID) '.mat']);
end
if ~isempty(file),bpil_capture_preflight(file);end
R=struct('schema','bpil_arm_control_result_v1','mode',mode,'action',action, ...
    'hardware_opened',false,'hardware_validated',false,'preflight',preflight, ...
    'hardware',H,'plan',plan,'session',[],'output_file',file, ...
    'scope','Controller-interface result; not payload accuracy or hardware qualification.');
if strcmp(mode,'dry_run'),save_result();return;end
% Resolve provenance before acquisition so a missing source cannot erase it.
files={'run_robot_control.m','src/bpil_arm_control_loop.m','src/bpil_arm_serial_transport.m', ...
    'src/bpil_arm_preflight.m','src/bpil_arm_control_profile.m','src/bpil_arm_plan.m', ...
    'src/bpil_capture_preflight.m','src/bpil_hefting_save.m', ...
    'vendor/bdcl_v29/bdclp_encode_command.m','vendor/bdcl_v29/bdclp_decode_feedback.m'};
R.source_files=files;R.source_sha256=cellfun(@(f)prc_file_hash(fullfile(root,f)),files,'UniformOutput',false);
assert(preflight.ready,'bpil:ArmPreflight','Preflight failed: %s',issues(preflight));
if strcmp(mode,'hardware')
    assert(isequal(get(opts,'enable_hardware',false),true),'bpil:ArmDisabled','Explicit enable_hardware=true is required.');
    assert(~isfield(opts,'transport'),'bpil:ArmTransport','Injected transports are mock-only.');
    assert(~H.fixture_only,'bpil:ArmFixture','Synthetic test profiles cannot open hardware.');
    assert(strlength(string(H.serial_port))>0,'bpil:ArmPort','Choose an explicit serial port.');
    T=bpil_arm_serial_transport(H.serial_port,H);R.hardware_opened=true;
else
    assert(isfield(opts,'transport')&&isstruct(opts.transport)&&isequal(opts.transport.is_mock,true), ...
        'bpil:ArmMock','Supply an explicitly marked virtual transport.');
    T=opts.transport;
end
cleanup=onCleanup(@()close_transport(T)); %#ok<NASGU>
try
    R.session=bpil_arm_control_loop(T,H,plan,O);
catch e
    % Defensive persistence if a core contract fails before its own capture.
    R.session=struct('completed',false,'reason',e.identifier,'error_message',e.message);
end
R.close_error='';
try,T.close();catch e,R.close_error=e.message;end
R.created_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
save_result();
    function save_result()
        if ~isempty(file),R.output_file=file;bpil_hefting_save(file,R);end
    end
end
function close_transport(T)
try,T.close();catch,end
end
function v=get(s,f,d),if isfield(s,f),v=s.(f);else,v=d;end,end
function s=issues(p)
if isempty(p.issues),s='unspecified';else,s=p.issues{1}.message;end
end
