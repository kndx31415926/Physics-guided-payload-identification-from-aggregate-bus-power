function report=test_robot_control()
%TEST_ROBOT_CONTROL Independent software contracts for arm commissioning.
% Does not open serial ports, load payload models, or require a power meter.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'),fullfile(root,'tests','helpers'));
checks={};started=tic;H=profile();
q0=[0 .20 -.10 .15];qf=[.08 .16 -.06 .12];
plan=bpil_arm_plan([q0;qf],1,.20);
base=struct('mode','mock','action','trajectory','hardware',H,'plan',plan, ...
    'max_time_s',4,'final_hold_s',.15,'final_tolerance_rad',.008);

% Default entry is inert even when a virtual transport is supplied.
[T,inspect]=bpil_mock_arm_control_transport(H,struct('initial_q',q0));
dry=run_robot_control(struct('transport',T));S=inspect();
assert(~dry.hardware_opened&&isempty(dry.session)&&isempty(S.sent)&&S.poll_calls==0&&S.close_count==0);
checks{end+1}='default dry run performs no transport I/O';

% Read-only stock discovery remains useful without pretending it is motion
% telemetry. Unknown signs and offsets never become calibrated joint angles.
unmapped=bpil_arm_control_profile();unmapped.fixture_only=true;
[stock,SS]=trial(struct('mode','mock','action','inspect','hardware',unmapped,'max_time_s',.30), ...
    unmapped,struct('telemetry','stock','initial_q',q0));
assert(~stock.hardware_opened&&~stock.hardware_validated);
assert(~isempty(stock.session.raw_frames)&&~isempty(stock.session.raw_wire_positions));
assert(isempty(stock.session.raw_positions)&&~stock.session.final_target_confirmed);
assert_no_motion(SS);assert(SS.close_count==1);
checks{end+1}='stock inspect records raw wire angles without fabricating calibrated positions or moving';

[unmapped_v2,VS]=trial(struct('mode','mock','action','inspect','hardware',unmapped,'max_time_s',.30), ...
    unmapped,struct('initial_q',q0));
assert(~isempty(unmapped_v2.session.raw_wire_positions)&&isempty(unmapped_v2.session.raw_positions));
assert_no_motion(VS);
assert(~unmapped_v2.session.final_target_confirmed);
checks{end+1}='compact telemetry with an unknown mapping remains observation-only';

[normal,NS]=trial(base,H,struct('initial_q',q0));
assert(normal.session.completed&&normal.session.final_target_confirmed, ...
    'test:ArmNominal','Nominal virtual control failed: %s',normal.session.reason);
assert(normal.session.torque_limits_verified&&~normal.hardware_opened&&~normal.hardware_validated);
assert(NS.close_count==1&&norm(NS.q-qf,Inf)<2e-6);
assert_spacing(NS);assert_only_safe_packets(NS);
assert(numel(normal.session.raw_positions)>=4);
last=normal.session.raw_positions;if iscell(last),last=[last{:}];end
assert(max(abs(last(end).q-qf))<2e-6,'test:ArmMapping','Sign/offset/tool-pitch inverse mapping failed.');
checks{end+1}='negative signs, distinct offsets and wrist-tool-pitch feedback recover model radians';
checks{end+1}='normal trajectory confirms fresh final settlement with 50-ms request/command spacing';

jointH=H;jointH.feedback_t_semantics='joint_angle';jointBase=base;jointBase.hardware=jointH;
[joint,JS]=trial(jointBase,jointH,struct('initial_q',q0,'wait_jitter_s',.0007));
assert(joint.session.completed&&joint.session.final_target_confirmed);
assert_spacing(JS);assert(norm(JS.q-qf,Inf)<2e-6);
checks{end+1}='joint-angle feedback and host jitter preserve calibrated mapping and cadence';

% Small drift remains inside tracking envelope, but cannot be called final
% arrival. The virtual arm deliberately ignores every target after startup.
[never_arrives,AS]=trial(base,H,struct('initial_q',q0,'ignore_motion',true));
assert(~never_arrives.session.completed&&~never_arrives.session.final_target_confirmed);
assert(AS.close_count==1&&norm(AS.q-q0,Inf)<1e-12);
checks{end+1}='power-free control cannot report completion when measured final position is wrong';

faults={struct('feedback_until_s',.30), ...
    struct('fault_after_s',.30,'reset_sequence',true), ...
    struct('fault_after_s',.30,'read_ok_mask',15), ...
    struct('fault_after_s',.30,'reported_mode',0), ...
    struct('fault_after_s',.30,'wrong_request_id',true)};
descriptions={'missing/stale feedback','device sequence reset','failed servo read', ...
    'wrong wrist mode','uncorrelated reply'};
for k=1:numel(faults)
    f=faults{k};f.initial_q=q0;[bad,BS]=trial(base,H,f);
    assert(~bad.session.completed&&~bad.session.final_target_confirmed, ...
        'test:ArmFault','%s was not rejected.',descriptions{k});
    assert(~strcmp(bad.session.reason,'completed')&&BS.close_count==1);
    assert_spacing(BS);assert_only_safe_packets(BS);
    % Correlated invalid data must prevent a motion command after delivery.
    if k>=2&&k<=4
        ix=cellfun(@(p)p.T==102,BS.sent);
        assert(all(BS.sent_times(ix)<BS.first_bad_frame_t+1e-12), ...
            'test:ArmFaultWrite','A motion target was sent after rejected correlated feedback.');
    end
    checks{end+1}=[descriptions{k} ' aborts without accepting a final state']; %#ok<AGROW>
end

% Tight reply timeout catches a missing response before the age limit.
timeoutH=H;timeoutH.request_timeout_s=.020;timeoutBase=base;timeoutBase.hardware=timeoutH;
[timeout,TS]=trial(timeoutBase,timeoutH,struct('initial_q',q0,'feedback_delay_s',.030));
assert(~timeout.session.completed&&isempty(timeout.session.commands));assert_no_motion(TS);
checks{end+1}='startup reply timeout prevents every motion command';

[badTorque,QS]=trial(base,H,struct('initial_q',q0,'torque_limits',[1000 1000 1000 1000 300]));
assert(~badTorque.session.completed&&~badTorque.session.torque_limits_verified);
assert_no_motion(QS);
checks{end+1}='unexpected torque-limit readback blocks motion without changing torque registers';

[wrongStart,WS]=trial(base,H,struct('initial_q',q0+[.10 0 0 0]));
assert(~wrongStart.session.completed);assert_no_motion(WS);
checks{end+1}='a displaced initial position is rejected rather than automatically approached';

lateBase=base;lateBase.max_io_overrun_s=.010;
[late,LS]=trial(lateBase,H,struct('initial_q',q0,'write_delay_after_s',.25,'command_write_delay_s',.020));
assert(~late.session.completed&&LS.close_count==1);
motion=cellfun(@(p)p.T==102,LS.sent);mt=LS.sent_times(motion);done=LS.write_completed_times(motion);
assert(sum(done-mt>.010)==1,'test:ArmLateWrite','Control continued after one blocking motion write.');
assert(mt(end)>=.25&&done(end)-mt(end)>.010);
checks{end+1}='a blocking motion write is recorded once and prevents subsequent targets';

% A stop arrives inside a blocking request, before a command could be sent.
[ST,si]=bpil_mock_arm_control_transport(H,struct('initial_q',q0, ...
    'request_write_delay_s',.030,'write_delay_after_s',.10));
stopBase=base;stopBase.transport=ST;stopBase.stop_requested=@()ST.now()>=.12;
stopped=run_robot_control(stopBase);STS=si();
assert(~stopped.session.completed&&~stopped.session.final_target_confirmed);
mi=cellfun(@(p)p.T==102,STS.sent);
assert(all(STS.sent_times(mi)<.12),'test:ArmStop','Motion was sent after stop became true inside request I/O.');
assert(STS.close_count==1);assert_only_safe_packets(STS);
checks{end+1}='stop during a blocking request is rechecked before the next motion write';

% Configuration problems are caught before construction of real transport.
badplan=plan;badplan.q(end,1)=H.model_qmax_rad(1)+.1;
invalid=base;invalid.mode='hardware';invalid.plan=badplan;invalid.enable_hardware=true;
invalid.hardware.serial_port='MUST_NOT_BE_OPENED';
expect_error(@()run_robot_control(invalid),'bpil:ArmPreflight');
unverified=base;unverified.mode='hardware';unverified.hardware=bpil_arm_control_profile();
unverified.enable_hardware=true;unverified.hardware.serial_port='MUST_NOT_BE_OPENED';
expect_error(@()run_robot_control(unverified),'bpil:ArmPreflight');
fixture=base;fixture.mode='hardware';fixture.enable_hardware=true;
fixture.hardware.serial_port='MUST_NOT_BE_OPENED';
expect_error(@()run_robot_control(fixture),'bpil:ArmFixture');
badLimits=H;badLimits.max_joint_speed_rad_s=.001*ones(1,4);
P=bpil_arm_preflight(badLimits,plan,'trajectory');assert(~P.ready);
P=bpil_arm_preflight(H,plan,'inspect');assert(~P.ready);
checks{end+1}='bad ranges/speeds and uncalibrated motion fail preflight before device opening';
checks{end+1}='a synthetic calibrated fixture cannot be used to open real hardware';
checks{end+1}='read-only inspection rejects a supplied motion plan';

% Persisted failure is as reviewable as a completed capture; neither is
% allowed to overwrite an existing result.
folder=fullfile(root,'tmp',['robot_control_tests_' char(java.util.UUID.randomUUID)]);mkdir(folder);
file=fullfile(folder,'partial_control_capture.mat');
savedOpts=base;savedOpts.output_file=file;
[saved,FS]=trial(savedOpts,H,struct('initial_q',q0,'feedback_until_s',.30));
assert(isfile(file)&&~saved.session.completed&&FS.close_count==1);
B=load(file,'session_result');assert(isequaln(B.session_result,saved));
assert(~isempty(saved.session.raw_positions)&&~isempty(saved.session.commands));
before=prc_file_hash(file);[ET,ei]=bpil_mock_arm_control_transport(H,struct('initial_q',q0));
existing=savedOpts;existing.transport=ET;
expect_error(@()run_robot_control(existing),'bpil:SessionExists');ES=ei();
assert(isempty(ES.sent)&&ES.poll_calls==0&&ES.close_count==0&&strcmp(before,prc_file_hash(file)));
checks{end+1}='partial fault capture is readable and existing files are rejected before I/O';

report=struct('pass',true,'check_count',numel(checks),'checks',{checks}, ...
    'seconds',toc(started),'result_folder',folder,'partial_capture',file, ...
    'scope','Virtual software protocol/commissioning tests only; no hardware, dynamics, power measurement or payload-accuracy validation.');
save(fullfile(folder,'robot_control_test_report.mat'),'report');disp(report);
end

function H=profile()
H=bpil_arm_control_profile();H.simulation_only=false;H.calibrated=true;H.fixture_only=true;
H.calibration_id='synthetic_arm_control_test';H.firmware_id='synthetic_v2_test';
H.ee_mode='wrist';H.long_rod_verified=true;H.position_source_verified=true;
H.probe_envelope_verified=true;H.payload_fixture_verified=true;H.allow_torque_limit_write=false;
H.sign=[-1 1 -1 1];H.zero_offset_rad=[.3 -.2 .4 .5];
H.model_qmin_rad=-ones(1,4);H.model_qmax_rad=ones(1,4);
a=H.sign.*H.model_qmin_rad+H.zero_offset_rad;b=H.sign.*H.model_qmax_rad+H.zero_offset_rad;
H.wire_qmin_rad=min(a,b);H.wire_qmax_rad=max(a,b);
H.feedback_t_semantics='wrist_tool_pitch';H.command_speed=200;H.command_acc=10;
H.max_joint_speed_rad_s=ones(1,4);H.max_joint_acc_rad_s2=5*ones(1,4);
H.max_command_step_rad=.05*ones(1,4);
end
function [R,S]=trial(options,H,mock)
[T,inspect]=bpil_mock_arm_control_transport(H,mock);options.transport=T;
R=run_robot_control(options);S=inspect();
end
function assert_no_motion(S)
assert(all(cellfun(@(a)a.T==105,S.sent)),'test:ArmReadOnly','Inspection sent a non-read packet.');
end
function assert_only_safe_packets(S)
assert(all(cellfun(@(a)any(a.T==[102 105]),S.sent)), ...
    'test:ArmConfigurationWrite','Mode, home, torque-limit or torque-enable command appeared.');
end
function assert_spacing(S)
for kind=[102 105]
    ix=cellfun(@(a)a.T==kind,S.sent);t=S.sent_times(ix);
    assert(all(diff(t)>=.05-1e-9),'test:ArmCadence','T%d was sent with a catch-up interval below 50 ms.',kind);
end
end
function expect_error(fn,identifier)
actual='';try,fn();catch e,actual=e.identifier;end
assert(strcmp(actual,identifier),'test:ArmError','Expected %s; got %s.',identifier,actual);
end
