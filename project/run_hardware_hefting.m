function R=run_hardware_hefting(opts)
%RUN_HARDWARE_HEFTING Serial acquisition -> eight poses -> PGAR estimate.
% Default dry_run opens nothing. Heavy inverse/NN inference follows capture.
if nargin<1,opts=struct();end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
allowed={'mode','cfg','hardware','probe','transport','power_provider','power_provider_factory', ...
    'model_file','eta','output_file','session','max_time_s','stop_requested', ...
    'max_tracking_error_rad','max_power_W','max_io_overrun_s','enable_hardware', ...
    'final_position_tolerance_rad','final_stationary_duration_s'};
assert(isstruct(opts)&&isscalar(opts)&&all(ismember(fieldnames(opts),allowed)),'bpil:HardwareOptions','Unknown hardware option.');
mode=get(opts,'mode','dry_run');assert(ismember(string(mode),["dry_run","mock","replay","hardware"]),'bpil:HardwareMode','Invalid mode.');
if isfield(opts,'output_file')&&~isempty(opts.output_file)
    assert(~isfile(opts.output_file),'bpil:SessionExists','Preserve the existing session; use a new output filename.');
    assert(~isfile(capture_name(opts.output_file)),'bpil:SessionExists','A raw checkpoint already exists; use a new output filename.');
end
output_file=get(opts,'output_file','');capture_file='';
if isempty(output_file)&&strcmp(mode,'hardware'),output_file=new_output_name(root);end
if ~isempty(output_file)
    bpil_capture_preflight(output_file);bpil_capture_preflight(capture_name(output_file));
end
model_file=get(opts,'model_file',fullfile(root,'results','pgar_nominal_20261029_v1','model_bundle.mat'));
if strcmp(mode,'replay')&&isfield(opts,'session')&&isfield(opts.session,'session')&&~isfield(opts,'model_file')
    model_file=opts.session.model_file;
    assert(strcmp(prc_file_hash(model_file),opts.session.model_sha256),'bpil:ReplayModelChanged','The originally recorded model file has changed.');
end
A=load(model_file,'bundle');bundle=A.bundle;
model_sha256=prc_file_hash(model_file);
assert(strcmp(bundle.schema,'pgar_residual_bundle_v1')&&numel(bundle.models)==3,'bpil:Bundle','Expected frozen three-seed residual bundle.');
cfg=get(opts,'cfg',bundle.cfg);cfg.root=root;H=get(opts,'hardware',bpil_hefting_hardware_profile());
probes=bpil_probe_library(cfg);probe=get(opts,'probe',probes(2));
eta=get(opts,'eta',struct('coefficients',bundle.power_coefficients));
if strcmp(mode,'replay')&&isfield(opts,'session')&&isfield(opts.session,'session')
    previous=opts.session;
    if ~isfield(opts,'cfg'),cfg=previous.cfg;cfg.root=root;end
    if ~isfield(opts,'hardware'),H=previous.hardware;end
    if ~isfield(opts,'probe'),probe=previous.probe;end
    if ~isfield(opts,'eta')&&isfield(previous,'eta'),eta=previous.eta;end
end
% Validate learner/calibration contracts before any device can be opened.
bpil_hefting_predict(bundle,struct(),eta);
assert(isequaln(cfg.sim,bundle.cfg.sim)&&isequaln(cfg.ident,bundle.cfg.ident)&& ...
    isequaln(cfg.payload,bundle.cfg.payload)&&isequaln(cfg.legacy.geometry,bundle.cfg.legacy.geometry), ...
    'bpil:ModelConfiguration','Estimator geometry, timing and bounds must match the trained bundle.');
assert(strcmp(probe.id,bundle.probe_id)&&isequal(probe.poses,probes(2).poses), ...
    'bpil:Probe','Use the trained probe_02 pose order.');
if strcmp(mode,'dry_run')
    [packet,wire]=bdclp_encode_command(struct('q',probe.poses(1,:),'speed',cfg.legacy.command.speed,'acc',cfg.legacy.command.acc),H,'simulation');
    R=struct('schema','bpil_hefting_dry_run_v1','mode',mode,'hardware_opened',false,'hardware_validated',false, ...
        'control_period_s',.05,'encoder_request_period_s',.05,'power_nominal_period_s',.01, ...
        'nominal_probe_duration_s',cfg.sim.initial_hold_s+8*(cfg.sim.move_s+cfg.sim.hold_s), ...
        'simulation_command_delay_s',.02,'packet',packet,'packet_info',wire,'profile_template',H, ...
        'model_file',model_file,'model_sha256',prc_file_hash(model_file), ...
        'required',{{'Locally calibrated robot mapping/limits and identified v2 firmware', ...
        'Verified fixture and swept probe envelope; pre-position at first pose', ...
        'Independent measured power provider on the transport monotonic clock'}}, ...
        'timing_scope','50 ms external schedule with asynchronous communication; no measured device-application ACK. Inference follows the full probe.');
    persist();return
end
if strcmp(mode,'replay')
    assert(isfield(opts,'session'),'bpil:Replay','Supply a recorded acquisition session.');
    session=opts.session;if isfield(session,'session'),session=session.session;end
    hardware_opened=false;
else
    preflight();
    if strcmp(mode,'hardware')
        assert(isequal(get(opts,'enable_hardware',false),true),'bpil:HardwareDisabled','Explicit enable_hardware=true is required.');
        assert(~isfield(opts,'transport'),'bpil:HardwareOverride','Injected transports are mock-only.');
        assert(~get(H,'fixture_only',false),'bpil:HardwareFixture','Synthetic hardware profiles cannot operate a robot.');
        assert(isfield(opts,'power_provider_factory')&&isa(opts.power_provider_factory,'function_handle'), ...
            'bpil:PowerProvider','Supply a factory that binds real power acquisition to the serial transport clock.');
        assert(~isfield(opts,'power_provider'),'bpil:PowerProvider','Live mode uses the clock-bound provider factory.');
        assert(isfield(opts,'model_file'),'bpil:HardwareModelSelection', ...
            'Select an explicitly verified hardware-compatible model_file. The default is the compact PGAR model, not the ridge-skip model.');
        T=bpil_arm_serial_transport(H.serial_port,H);hardware_opened=true;
    else
        assert(isfield(opts,'transport')&&isequal(opts.transport.is_mock,true),'bpil:MockTransport','An explicit mock transport is required.');
        T=opts.transport;hardware_opened=false;
    end
    tc=onCleanup(@()T.close()); %#ok<NASGU>
    assert(strcmp(T.clock_id,H.clock_id),'bpil:Clock','Transport and profile clock identifiers differ.');
    if isfield(opts,'power_provider_factory')
        source=opts.power_provider_factory(T.now,H);
        assert(isstruct(source)&&all(isfield(source,{'poll','close'}))&&isa(source.poll,'function_handle')&&isa(source.close,'function_handle'), ...
            'bpil:PowerProvider','Factory returns a struct with nonblocking poll(now) and idempotent close().');
        pc=onCleanup(source.close);provider=source.poll; %#ok<NASGU>
    else
        assert(isfield(opts,'power_provider')&&isa(opts.power_provider,'function_handle'),'bpil:PowerProvider','Provide a nonblocking independent power source.');
        provider=opts.power_provider;
    end
    loop_options=struct();
    for f={'max_time_s','stop_requested','max_tracking_error_rad','max_power_W','max_io_overrun_s', ...
            'final_position_tolerance_rad','final_stationary_duration_s'}
        if isfield(opts,f{1}),loop_options.(f{1})=opts.(f{1});end
    end
    session=bpil_hefting_loop(T,provider,H,cfg,probe,loop_options);
    session.hardware_opened=hardware_opened;
    clear tc pc
end
% Checkpoint raw acquisition before observation building or neural inference.
% A postprocessing error cannot erase the only copy of a real acquisition.
if ~strcmp(mode,'replay')
    if isempty(output_file)&&strcmp(mode,'hardware'),output_file=new_output_name(root);end
    if ~isempty(output_file)
        capture_file=capture_name(output_file);
        raw_result=struct('schema','bpil_hefting_raw_checkpoint_v1','mode',mode, ...
            'session',session,'cfg',cfg,'hardware',H,'probe',probe,'eta',eta, ...
            'hardware_opened',hardware_opened,'hardware_validated',false, ...
            'model_file',model_file,'model_sha256',model_sha256, ...
            'postprocessing_completed',false,'output_file',output_file);
        bpil_hefting_save(capture_file,raw_result);
    end
end
obs=bpil_hefting_observation(session,cfg,probe,H);
started=tic;prediction=bpil_hefting_predict(bundle,obs,eta);inference_s=toc(started);
R=struct('schema','bpil_hefting_session_result_v1','mode',mode,'session',session,'obs',obs,'prediction',prediction, ...
    'completed',session.completed,'hardware_opened',hardware_opened,'hardware_validated',false, ...
    'cfg',cfg,'hardware',H,'probe',probe,'eta',eta,'model_file',model_file,'model_sha256',prc_file_hash(model_file), ...
    'inference_after_capture_s',inference_s,'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'parameter_names',{{'mass_kg','com_x_m','com_z_m'}}, ...
    'scope','One recorded probe; mock/replay do not establish hardware performance. A model estimate is not a ground-truth label.', ...
    'raw_checkpoint_file',capture_file);
files={'run_hardware_hefting.m','src/bpil_hefting_loop.m','src/bpil_hefting_observation.m','src/bpil_hefting_save.m', ...
    'src/bpil_hefting_features.m','src/bpil_hefting_predict.m','src/bpil_arm_serial_transport.m', ...
    'vendor/bdcl_v29/bdclp_encode_command.m','vendor/bdcl_v29/bdclp_decode_feedback.m'};
R.source_files=files;R.source_sha256=cellfun(@(x)prc_file_hash(fullfile(root,x)),files,'UniformOutput',false);
persist();
    function preflight()
        assert(~H.simulation_only&&H.calibrated&&strcmp(H.ee_mode,'wrist')&&H.long_rod_verified&&H.position_source_verified, ...
            'bpil:HardwareProfile','Use a calibrated local profile with verified wrist/encoder/fixture installation.');
        assert(get(H,'probe_envelope_verified',false)&&get(H,'payload_fixture_verified',false), ...
            'bpil:HardwareProfile','Verify the swept probe envelope and rigid payload fixture.');
        assert(H.control_dt_s==.05&&cfg.legacy.clock.control_dt_s==.05,'bpil:HardwareCadence','Expected 50 ms position schedule.');
        assert(~H.allow_torque_limit_write,'bpil:HardwareTorqueWrite','Configure torque limits separately; this acquisition only reads them.');
        assert(H.baud_rate==cfg.legacy.transport.baud_rate,'bpil:BaudContract','Explicitly match the configured baud rate.');
        assert(isequal(H.required_torque_limit_register,cfg.legacy.servo.torque_limit_register),'bpil:TorqueLimitContract','Torque limits differ from the declared model.');
        for j=1:size(probe.poses,1)
            bdclp_encode_command(struct('q',probe.poses(j,:),'speed',cfg.legacy.command.speed,'acc',cfg.legacy.command.acc),H,'hardware');
        end
    end
    function persist()
        file=output_file;
        if isempty(file)&&strcmp(mode,'hardware')
            file=new_output_name(root);output_file=file;
        end
        if ~isempty(file)
            assert(~isfile(file),'bpil:SessionExists','Preserve the existing session; use a new output filename.');
            R.output_file=file;bpil_hefting_save(file,R);
        end
    end
end
function v=get(S,f,d),if isfield(S,f),v=S.(f);else,v=d;end,end
function file=capture_name(output)
[folder,name,~]=fileparts(output);file=fullfile(folder,[name '_capture.mat']);
assert(~strcmp(char(output),file),'bpil:SessionName','Output and raw-checkpoint filenames must differ.');
end
function file=new_output_name(root)
folder=fullfile(root,'results','hardware_sessions');if ~isfolder(folder),mkdir(folder);end
file=fullfile(folder,['heft_' char(datetime('now','Format','yyyyMMdd_HHmmss')) '_' char(javaMethod('randomUUID','java.util.UUID')) '.mat']);
end
