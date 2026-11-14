function report=test_hardware_hefting()
%TEST_HARDWARE_HEFTING Virtual transport, safety gates, replay and inference.
% These tests never open hardware. Static synthesized power and instant
% mock position changes validate software plumbing, not physical accuracy.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'), ...
    fullfile(root,'tests','helpers'));
started=tic;checks={};verify_frozen_sources(root);
a=load(fullfile(root,'results','pgar_nominal_20261029_v1','configuration.mat'),'cfg');
cfg=a.cfg;cfg.root=root;probes=bpil_probe_library(cfg);probe=probes(2);H=profile();
base=struct('mode','mock','cfg',cfg,'hardware',H,'probe',probe,'max_time_s',45);

dry=run_hardware_hefting(struct('cfg',cfg));
assert(~dry.hardware_opened,'test:DryRun','Default dry run opened hardware.');
checks{end+1}='default dry run opens no device';

[normal,S]=trial(base,H,cfg,probe,struct());
assert(normal.completed&&~normal.hardware_opened&&~normal.hardware_validated, ...
    'test:Nominal','Normal mock failed: %s: %s',normal.session.reason,normal.session.error_message);
assert(S.close_count==1,'test:Cleanup','Transport cleanup must execute exactly once.');
assert(isequal(size(normal.obs.plateau_q),[8 4])&&all(normal.obs.stationary));
assert(numel(normal.obs.t)>2000&&all(diff(normal.obs.t)>0));
assert(normal.prediction.accepted&&all(isfinite(normal.prediction.theta)), ...
    'test:Pipeline','Synthetic valid plateau signal must reach the frozen residual network.');
assert_causal_alignment(normal);
assert_timing(normal.session,S);
assert(all(cellfun(@(x)x.T~=210,S.sent)),'test:Torque','Exit must not silently disable torque.');
assert(all(cellfun(@(x)x.T~=107,S.sent)),'test:TorqueWrite','Read-only torque verification must not write a torque limit.');
checks{end+1}='complete eight-pose acquisition and frozen residual-model inference';
checks{end+1}='20 Hz command spacing, non-ACK timing metadata and single cleanup';

[jitter,JS]=trial(base,H,cfg,probe,struct('wait_jitter_s',.0007));
assert(jitter.completed);assert_timing(jitter.session,JS);assert_causal_alignment(jitter);
checks{end+1}='host wait jitter never compresses successive command periods';

replayopts=base;replayopts.mode='replay';replayopts.session=normal;
replayopts.transport=struct('now',@forbidden_io,'poll',@forbidden_io, ...
    'write',@forbidden_io,'wait',@forbidden_io,'close',@forbidden_io);
replayopts.power_provider=@forbidden_io;
replayed=run_hardware_hefting(replayopts);
assert(replayed.completed&&~replayed.hardware_opened);
assert(isequaln(replayed.obs,normal.obs));
assert(max(abs(replayed.prediction.theta-normal.prediction.theta))<1e-12);
checks{end+1}='replay consumes stored observations without transport or power I/O';

missing=normal.session;w=normal.obs.plateau_windows_host_s(3,:);
keep=cellfun(@(x)x.sample_t<w(1)||x.sample_t>w(2),missing.raw_power);
missing.raw_power=missing.raw_power(keep);replayopts.session=missing;
incomplete=run_hardware_hefting(replayopts);
assert(~incomplete.obs.acquisition_valid&&~incomplete.prediction.accepted);
checks{end+1}='missing any plateau rejects inference even when a stored session claims completion';

[T,power,inspect]=bpil_mock_hefting_transport(H,cfg,probe);
stopopts=base;stopopts.transport=T;stopopts.power_provider=power;
stopopts.stop_requested=@()T.now()>=1;
stopped=run_hardware_hefting(stopopts);SS=inspect();
assert(~stopped.completed&&strcmp(stopped.session.reason,'stopped_by_user')&&SS.close_count==1);
checks{end+1}='user stop terminates collection and closes once';

expect_failure(base,H,cfg,probe,struct('power_until',1),'bpil:StalePower');
checks{end+1}='held or missing power samples become stale';

FH=H;FH.request_timeout_s=.030;FH.max_feedback_age_s=.5;
feedbackopts=base;feedbackopts.hardware=FH;
expect_failure(feedbackopts,FH,cfg,probe,struct('feedback_until',1),'bpil:FeedbackTimeout');
checks{end+1}='missing correlated feedback reaches the explicit request timeout';

expect_failure(base,H,cfg,probe,struct('power_future_s',.1,'power_fault_after_s',1), ...
    'bpil:FutureObservation');
checks{end+1}='future-dated power samples are rejected';
expect_failure(base,H,cfg,probe,struct('power_calibrated',false,'power_fault_after_s',1), ...
    'bpil:PowerProvider');
checks{end+1}='uncalibrated power is rejected';
expect_failure(base,H,cfg,probe,struct('power_nan',true,'power_fault_after_s',1), ...
    'bpil:PowerProvider');
checks{end+1}='nonfinite power is rejected';

poweropts=base;poweropts.max_power_W=100;
expect_failure(poweropts,H,cfg,probe,struct('power_offset_W',1000,'power_fault_after_s',1), ...
    'bpil:PowerLimit');
checks{end+1}='power envelope violation aborts acquisition';
trackingopts=base;trackingopts.max_tracking_error_rad=.1;
expect_failure(trackingopts,H,cfg,probe,struct('tracking_offset_rad',[.2 0 0 0]), ...
    'bpil:TrackingError');
checks{end+1}='measured tracking-error envelope violation aborts acquisition';
ioopts=base;ioopts.max_io_overrun_s=.005;
expect_failure(ioopts,H,cfg,probe,struct('write_delay_s',.02,'write_delay_after_s',1), ...
    'bpil:IOOverrun');
checks{end+1}='blocking transport call is detected as an I/O overrun';

[limits,LS]=trial(base,H,cfg,probe,struct('torque_limits',[1000 1000 1000 1000 300]));
assert(~limits.completed&&strcmp(limits.session.reason,'bpil:TorqueLimitReadback'));
assert(~any(cellfun(@(x)x.T==102,LS.sent))&&LS.close_count==1);
checks{end+1}='incorrect torque-limit readback prevents the first position command';

unconfigured=bdclp_interface_defaults();unconfigured.serial_port='UNOPENABLE_TEST_PORT';
unsafe=struct('mode','hardware','cfg',cfg,'hardware',unconfigured,'probe',probe, ...
    'power_provider_factory',@forbidden_io,'enable_hardware',true);
rejected=false;identifier='';
try
    invalid=run_hardware_hefting(unsafe); %#ok<NASGU>
catch err
    identifier=err.identifier;
    rejected=~strcmp(identifier,'test:ForbiddenIO')&& ...
        (contains(lower(err.message),'calibrat')||contains(lower(identifier),'calibrat')|| ...
        contains(lower(identifier),'hardwareprofile')||contains(lower(identifier),'hardwaregate'));
end
assert(rejected,'test:HardwareGate','Uncalibrated hardware was not rejected before I/O (%s).',identifier);
checks{end+1}='uncalibrated hardware is rejected before transport construction or sampling';

verify_frozen_sources(root);
checks{end+1}='nominal and formal robustness/continual frozen source manifests remain valid';
report=struct('pass',true,'checks',{checks},'check_count',numel(checks), ...
    'seconds',toc(started),'nominal_commands',numel(normal.session.commands), ...
    'nominal_power_samples',numel(normal.obs.t), ...
    'synthetic_prediction',normal.prediction.theta, ...
    'scope','Virtual I/O and static synthetic power only; not a hardware, dynamics, accuracy, or robustness experiment');
disp(report);
end

function [R,S]=trial(base,H,cfg,probe,fault)
[T,power,inspect]=bpil_mock_hefting_transport(H,cfg,probe,fault);
opts=base;opts.transport=T;opts.power_provider=power;
R=run_hardware_hefting(opts);S=inspect();
end

function expect_failure(base,H,cfg,probe,fault,reason)
[R,S]=trial(base,H,cfg,probe,fault);
assert(~R.completed&&strcmp(R.session.reason,reason),'test:Fault', ...
    'Expected %s, got %s: %s',reason,R.session.reason,R.session.error_message);
assert(S.close_count==1,'test:Cleanup','Failed session did not close exactly once.');
assert(~R.prediction.accepted,'test:PredictionGate','Aborted acquisition produced an accepted estimate.');
end

function assert_timing(R,S)
position=cellfun(@(x)x.T==102,S.sent);times=S.sent_times(position);
assert(numel(times)>400&&all(diff(times)>=.05-1e-9),'test:Timing', ...
    'Position commands must remain at least 50 ms apart without catch-up bursts.');
assert(numel(R.commands)==numel(times));
for k=1:numel(R.commands)
    x=R.commands{k};
    assert(x.write_completed_t>=x.sent_t&&x.tx_end_estimate>=x.sent_t&& ...
        x.applied_estimate>=x.tx_end_estimate,'test:Timing','Invalid I/O timestamp ordering.');
    if isfield(x,'acknowledged'),assert(~x.acknowledged);end
end
end

function assert_causal_alignment(R)
O=R.obs;actual=O.t+O.host_time_origin_s;
assert(all(O.position_received_t<=actual+1e-9));
assert(all(O.position_sample_t<=O.position_received_t));
assert(all(O.power_received_t>=actual-1e-9));
P=R.session.raw_power;stamps=cellfun(@(x)x.sample_t,P);
for k=1:numel(actual)
    assert(any(abs(stamps-actual(k))<1e-10),'test:TimeWarp', ...
        'Observation time must be an actual recorded power acquisition, not a nominal resampling.');
end
for k=1:8
    reference=R.cfg.sim.initial_hold_s+k*(R.cfg.sim.move_s+R.cfg.sim.hold_s);
    ix=find(cellfun(@(x)x.reference_t>=reference-1e-9,R.session.commands),1);
    assert(abs(O.plateau_windows_host_s(k,2)-R.session.commands{ix}.sent_t)<1e-12);
end
end

function H=profile()
H=bdclp_interface_defaults();H.simulation_only=false;H.calibrated=true;
H.calibration_id='synthetic_mock_only';H.firmware_id='synthetic_mock_only';
H.ee_mode='wrist';H.long_rod_verified=true;H.position_source_verified=true;
H.allow_torque_limit_write=false;H.sign=ones(1,4);H.zero_offset_rad=[0 0 0 pi];
H.model_qmin_rad=-2*ones(1,4);H.model_qmax_rad=2*ones(1,4);
H.wire_qmin_rad=H.model_qmin_rad+H.zero_offset_rad;
H.wire_qmax_rad=H.model_qmax_rad+H.zero_offset_rad;
H.feedback_t_semantics='joint_angle';H.probe_envelope_verified=true;
H.payload_fixture_verified=true;
end

function verify_frozen_sources(root)
names={'pgar_nominal_20261029_v1','pra_robust_20261030_v1','pra_continual_20261030_v1'};
for k=1:numel(names)
    folder=fullfile(root,'results',names{k});manifest=fullfile(folder,'source_manifest.csv');
    if ~isfile(manifest),continue;end
    M=readtable(manifest,'Delimiter',',','TextType','string','NumHeaderLines',0, ...
        'VariableNamingRule','preserve');
    for j=1:height(M)
        path=fullfile(folder,'source_snapshot',char(M.relative_path(j)));
        assert(strcmp(prc_file_hash(path),char(M.sha256(j))),'test:FrozenMutation', ...
            'Frozen experiment source changed: %s',path);
    end
end
end

function varargout=forbidden_io(varargin) %#ok<STOUT,INUSD>
error('test:ForbiddenIO','Test attempted forbidden live I/O.');
end
