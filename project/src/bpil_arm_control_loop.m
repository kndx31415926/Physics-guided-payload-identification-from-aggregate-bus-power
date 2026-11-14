function R=bpil_arm_control_loop(T,H,plan,O)
%BPIL_ARM_CONTROL_LOOP Independent request-correlated arm-control session.
% The caller validates a local profile/trajectory before opening T. This loop
% does not open a port, load a learner, sample power, alter mode/torque, or
% reconnect. Actual request and command starts remain >= control_dt_s apart.
% A late host stretches wall duration; every reference row is sent once.
% Software stop only stops new writes. It is not an emergency stop: already
% issued targets and the servo torque state remain unchanged.
R=struct('schema','bpil_arm_control_session_v1','action',O.action, ...
    'completed',false,'reason','time_limit','error_message','', ...
    'raw_frames',{{}},'raw_positions',{{}},'raw_wire_positions',{{}}, ...
    'requests',{{}},'writes',{{}},'commands',{{}},'events',{{}}, ...
    'started_t',NaN,'motion_start_t',NaN,'terminal_command_t',NaN, ...
    'ended_t',NaN,'control_period_s',H.control_dt_s,'is_mock',T.is_mock, ...
    'clock_id',T.clock_id,'hardware_opened',false, ...
    'hardware_opened_by_loop',false,'hardware_validated',false, ...
    'torque_limits_verified',false,'torque_disabled_on_exit',false, ...
    'final_target_confirmed',false,'final_confirmation_samples',0, ...
    'capability','unknown','source_status',struct( ...
    'request_correlated',false,'acquisition_verified',false, ...
    'joint_mapping_verified',false,'usable_for_control',false), ...
    'exit_action',['Stop sending and close the host transport; retain the ' ...
    'last issued target and unchanged servo torque. Not an emergency stop.']);
last_clock=-Inf;last_raw_receipt=-Inf;pending=[];state=[];last_position=[];
last_request_id=0;last_request_sent=-Inf;last_command_sent=-Inf;
limits_verified=false;next_row=1;final_hold_start=NaN;final_samples=0;
last_final_seq=NaN;final_preceding_request_id=Inf;closed=false;inspect_done=false;
cleanup=onCleanup(@close_once); %#ok<NASGU>
try
    assert(any(strcmp(O.action,{'inspect','trajectory'})), ...
        'bpil:ControlAction','Unknown control action.');
    assert(abs(H.control_dt_s-.05)<1e-12,'bpil:ControlPeriod', ...
        'The external command period must be 50 ms.');
    assert(strcmp(T.clock_id,H.clock_id),'bpil:ClockMismatch', ...
        'Transport and profile must share one monotonic host clock.');
    mapped=isequal(H.calibrated,true)&&~H.simulation_only&& ...
        ~isempty(H.calibration_id)&&~isempty(H.firmware_id)&& ...
        isequal(H.position_source_verified,true);
    if strcmp(O.action,'trajectory')
        assert(mapped,'bpil:UncalibratedInterface', ...
            'Motion requires an independently calibrated and verified profile.');
        validateattributes(plan.t,{'numeric'},{'column','real','finite','nonnegative','nonempty'});
        validateattributes(plan.q,{'numeric'},{'2d','real','finite','ncols',4,'nonempty'});
        assert(numel(plan.t)==size(plan.q,1)&&abs(plan.t(1))<1e-12&& ...
            all(abs(diff(plan.t)-H.control_dt_s)<1e-9), ...
            'bpil:ControlPlan','Trajectory rows must start at zero on the 50-ms grid.');
    end
    R.started_t=clock_now();
    while clock_now()-R.started_t<=O.max_time_s
        check_stop();
        before=clock_now();frames=T.poll();after=clock_now();
        assert(iscell(frames),'bpil:TransportPoll','poll must return a cell array.');
        % Preserve the complete batch before decoding: a bad first frame must
        % not discard the remaining raw records returned by the same poll.
        for k=1:numel(frames),R.raw_frames{end+1}=frames{k};end
        io_check(before,after,'poll');
        for k=1:numel(frames),accept_frame(frames{k});end
        t=clock_now();
        time_check(t);
        if inspect_done,R.completed=true;R.reason='inspection_completed';break;end
        if ~isempty(pending)&&t-pending.request_t>H.request_timeout_s
            error('bpil:FeedbackTimeout','Outstanding feedback exceeded %.3f s.',H.request_timeout_s);
        end
        if isnan(R.motion_start_t)
            if t-R.started_t>H.startup_timeout_s
                error('bpil:HardwareStartup', ...
                    'Verified feedback and required torque-limit readback were not obtained.');
            end
        else
            assert_fresh(t);
            assert_tracking(R.commands{end}.q);
        end
        % Completion uses multiple distinct, post-final-command acquisitions.
        % It confirms observed target tolerance, not unobserved continuous
        % stationarity or physical motion arrest between samples.
        if ~isnan(R.terminal_command_t)&&isempty(pending)&& ...
                final_samples>=2&&~isnan(final_hold_start)&& ...
                last_position.sample_t-final_hold_start>=O.final_hold_s-1e-12
            assert_fresh(t);R.completed=true;R.reason='completed';
            R.final_target_confirmed=true;break;
        end
        if isempty(pending)&&t-last_request_sent>=H.control_dt_s-1e-12
            assert(last_request_id<2^32-1,'bpil:RequestIdExhausted', ...
                'Request identifier range exhausted; open a new explicit session.');
            id=last_request_id+1;
            data=struct('request_id',id,'read_limits',~limits_verified);
            packet=bdclp_wire_packet('position_request',data,H,'hardware');
            D=write_packet(packet,'position_request',[],NaN);
            assert(D.sent_t-last_request_sent>=H.control_dt_s-1e-12, ...
                'bpil:RequestCadence','Feedback requests are less than 50 ms apart.');
            pending=struct('request_t',D.sent_t,'request_id',id,'clock_id',H.clock_id);
            last_request_sent=D.sent_t;last_request_id=id;
            request=struct('request_id',id,'request_t',D.sent_t, ...
                'read_limits',data.read_limits,'write_completed_t',D.write_completed_t, ...
                'packet',packet);
            R.requests{end+1}=request;
        end
        % Re-read the clock after the request write. Reusing the time from
        % before a blocking write could authorize motion from stale feedback.
        t=clock_now();time_check(t);
        if strcmp(O.action,'trajectory')&&limits_verified&&~isempty(last_position)&& ...
                next_row<=size(plan.q,1)&&t-last_command_sent>=H.control_dt_s-1e-12
            assert_fresh(t);
            if isnan(R.motion_start_t)
                assert(max(abs(last_position.q-plan.q(1,:)))<=H.start_position_tolerance_rad, ...
                    'bpil:InitialPose','Pre-position the arm at the first trajectory pose.');
            end
            q=plan.q(next_row,:);assert_tracking(q);
            [packet,W]=bdclp_encode_command(struct('q',q,'speed',O.speed,'acc',O.acc),H,'hardware');
            D=write_packet(packet,'position_command',q,plan.t(next_row));
            assert(D.sent_t-last_command_sent>=H.control_dt_s-1e-12, ...
                'bpil:CommandCadence','Motion command starts are less than 50 ms apart.');
            R.commands{end}.byte_count=W.byte_count;
            R.commands{end}.wire_duration_lower_bound_s=W.tx_lower_bound_s;
            if isnan(R.motion_start_t),R.motion_start_t=D.sent_t;end
            last_command_sent=D.sent_t;
            if next_row==size(plan.q,1)
                R.terminal_command_t=D.sent_t;
                R.terminal_write_completed_t=D.write_completed_t;
                final_preceding_request_id=last_request_id;
            end
            next_row=next_row+1;
        end
        before=clock_now();T.wait(H.poll_pause_s);after=clock_now();
        io_check(before,after,'wait');
    end
catch e
    R.source_status.usable_for_control=false;
    if strcmp(e.identifier,'bpil:StopRequested'),R.reason='stopped_by_user';
    elseif strcmp(e.identifier,'bpil:TimeLimit'),R.reason='time_limit';
    else,R.reason=e.identifier;end
    R.error_message=e.message;
    R.events{end+1}=struct('kind','abort','time',last_clock, ...
        'identifier',e.identifier,'message',e.message);
end
R.torque_limits_verified=limits_verified;
R.final_confirmation_samples=final_samples;
R.pending_request=pending;
if isempty(last_position),R.last_position_received_t=NaN;
else,R.last_position_received_t=last_position.received_t;end
try,R.ended_t=clock_now();catch,R.ended_t=last_clock;end
close_once();
% Destroy the guard while this shared nested-function workspace is still
% active. MATLAB may otherwise invoke its nested callback during teardown,
% after the captured closed flag is no longer accessible.
clear cleanup

    function t=clock_now()
        t=T.now();
        validateattributes(t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(t>=last_clock,'bpil:ClockOrder','Transport clock moved backwards.');
        last_clock=t;
    end
    function check_stop()
        before=clock_now();stop=O.stop_requested();after=clock_now();
        io_check(before,after,'stop_requested');
        assert(islogical(stop)&&isscalar(stop),'bpil:StopCallback', ...
            'stop_requested must return a scalar logical.');
        if stop,error('bpil:StopRequested','Software stop requested; no further writes.');end
    end
    function D=write_packet(packet,kind,q,reference_t)
        check_stop();before=clock_now();time_check(before);
        if strcmp(kind,'position_command')
            assert_fresh(before);assert_tracking(q);
            assert(limits_verified,'bpil:TorqueLimitReadback', ...
                'Required torque-limit readback has not been verified.');
        end
        idx=numel(R.writes)+1;
        R.writes{idx}=struct('kind',kind,'attempt_t',before, ...
            'packet',packet,'returned',false,'delivery_ambiguous',true, ...
            'acknowledged',false,'q',q,'reference_t',reference_t);
        try
            D=T.write(packet);after=clock_now();
        catch e
            R.writes{idx}.identifier=e.identifier;
            R.writes{idx}.message=e.message;
            R.events{end+1}=struct('kind','write_exception', ...
                'time',last_clock,'write_index',idx,'delivery_ambiguous',true);
            rethrow(e);
        end
        R.writes{idx}.returned=true;R.writes{idx}.transport_result=D;
        R.writes{idx}.return_t=after;
        % A completed host write is not an acknowledgement or proof of
        % firmware application. Keep it even if validation/overrun fails.
        if strcmp(kind,'position_command')
            if ~isstruct(D)||~isscalar(D),C=struct('transport_result',D);else,C=D;end
            C.packet=packet;C.q=q;C.reference_t=reference_t;
            C.acknowledged=false;C.application_time_verified=false;
            C.position_sample_t=last_position.sample_t;
            C.position_received_t=last_position.received_t;
            R.commands{end+1}=C;
        end
        validate_write(D,before,after);
        R.writes{idx}.delivery_ambiguous=false;
        io_check(before,after,kind);
    end
    function accept_frame(f)
        assert(isstruct(f)&&isscalar(f)&&all(isfield(f,{'raw','received_t'})), ...
            'bpil:TransportFrame','Transport returned an incomplete raw frame.');
        validateattributes(f.received_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(f.received_t<=clock_now()+1e-9,'bpil:FutureObservation', ...
            'Frame receipt timestamp is in the future.');
        assert(f.received_t>=last_raw_receipt,'bpil:ReceiptOrder', ...
            'Raw frame receipt timestamps moved backwards.');
        last_raw_receipt=f.received_t;
        try,a=jsondecode(char(f.raw));catch
            event('ignored_non_json_frame',f.received_t);return;
        end
        if ~isstruct(a)||~isscalar(a)||~isfield(a,'T')||~isequal(a.T,1051)
            event('ignored_unrelated_frame',f.received_t);return;
        end
        fields={'b','s','e','t'};wire=zeros(1,4);
        for j=1:4
            assert(isfield(a,fields{j}),'bpil:FeedbackFrame','Missing raw angle field.');
            validateattributes(a.(fields{j}),{'numeric'},{'scalar','real','finite'});
            wire(j)=a.(fields{j});
        end
        R.raw_wire_positions{end+1}=struct('b',wire(1),'s',wire(2), ...
            'e',wire(3),'t',wire(4),'received_t',f.received_t, ...
            'joint_angles_verified',false,'usable_for_control',false,'raw',f.raw);
        if ~isfield(a,'fver')||~isequal(a.fver,2)
            R.capability='stock_unverified';
            if strcmp(O.action,'inspect')
                event('stock_feedback_has_no_verified_acquisition_or_joint_mapping',f.received_t);
                inspect_done=true;return;
            end
            error('bpil:TelemetryVersion','Motion requires compact v2 acquisition telemetry.');
        end
        assert(~isempty(pending)&&isfield(a,'freq')&&isequal(a.freq,pending.request_id), ...
            'bpil:UncorrelatedFeedback','Position reply does not match the outstanding request.');
        validate_compact(a,f.received_t);
        if ~mapped
            R.capability='telemetry_v2_unmapped';
            R.source_status.request_correlated=true;
            R.source_status.acquisition_verified=true;
            check_limits(a,true);pending=[];inspect_done=true;return;
        end
        [obs,decoded]=bdclp_decode_feedback(a,f.received_t,H,state,pending);
        p=obs.position_sample;
        p.clock_id=H.clock_id;p.sample_time_window_s=obs.sample_time_window_s;
        p.sample_time_exact=false;p.sample_t_is_request_lower_bound=true;
        p.request_id=pending.request_id;p.raw=f.raw;
        p.torque_limit_register=obs.torque_limit_register;
        R.raw_positions{end+1}=p;
        assert(obs.position_fresh,'bpil:InvalidFeedback', ...
            'Feedback failed source, acquisition, order, age or configured-mode verification.');
        check_limits(a,~limits_verified);
        state=decoded;last_position=p;pending=[];
        R.capability='telemetry_v2_verified';
        R.source_status=struct('request_correlated',true,'acquisition_verified',true, ...
            'joint_mapping_verified',true,'usable_for_control',limits_verified);
        if strcmp(O.action,'inspect'),inspect_done=true;return;end
        if ~isnan(R.terminal_command_t)&&p.sample_t>=R.terminal_write_completed_t&& ...
                p.request_id>final_preceding_request_id&&p.seq~=last_final_seq
            last_final_seq=p.seq;
            if max(abs(p.q-plan.q(end,:)))<=O.final_tolerance_rad
                if isnan(final_hold_start),final_hold_start=p.sample_t;end
                final_samples=final_samples+1;
            else
                final_hold_start=NaN;final_samples=0;
            end
        end
    end
    function validate_compact(a,received_t)
        required={'freq','fseq','fmode','fok','ft0','ft1'};
        assert(all(isfield(a,required)),'bpil:TelemetryFields','Incomplete compact v2 frame.');
        for name={'freq','ft0','ft1'}
            validateattributes(a.(name{1}),{'numeric'}, ...
                {'scalar','real','finite','integer','>=',0,'<=',2^32-1});
        end
        validateattributes(a.fseq,{'numeric'},{'scalar','real','finite','integer','>=',1,'<=',2^32-1});
        validateattributes(a.fmode,{'numeric'},{'scalar','real','finite','integer','>=',0,'<=',1});
        assert(isequal(a.fok,31),'bpil:ServoReadFailed','All five physical servo reads must succeed.');
        assert(received_t>=pending.request_t&&received_t-pending.request_t<=H.max_feedback_age_s, ...
            'bpil:StalePosition','Reply age exceeded the configured sample-age bound.');
        span=mod(double(a.ft1)-double(a.ft0),2^32)*1e-6;
        assert(span<=H.max_acquisition_span_s,'bpil:AcquisitionSpan', ...
            'Sequential servo acquisition span exceeded its configured bound.');
        if ~isempty(state)&&isfield(state,'last_device_seq')
            assert(a.fseq>state.last_device_seq,'bpil:FeedbackSequence', ...
                'Device sequence repeated, reset or moved backwards.');
        end
    end
    function check_limits(a,required)
        if ~isfield(a,'flim')
            assert(~required,'bpil:TorqueLimitReadback','Requested five-servo torque-limit readback is missing.');
            return;
        end
        lim=reshape(a.flim,1,[]);
        validateattributes(lim,{'numeric'},{'real','finite','integer','numel',5,'>=',0,'<=',1000});
        R.last_torque_limit_register=lim;
        wanted=H.required_torque_limit_register([1 2 2 3 4]);
        assert(isequal(lim,wanted),'bpil:TorqueLimitReadback', ...
            'Measured five-servo torque limits differ from the configured required values.');
        if ~limits_verified,event('required_torque_limits_verified',last_clock);end
        limits_verified=true;
    end
    function assert_fresh(t)
        assert(~isempty(last_position)&&last_position.valid&& ...
            last_position.received_t<=t+1e-9&&t-last_position.sample_t<=H.max_feedback_age_s, ...
            'bpil:StalePosition','No currently fresh verified joint-position acquisition.');
    end
    function assert_tracking(q)
        assert(max(abs(last_position.q-q))<=O.max_tracking_error_rad, ...
            'bpil:TrackingError','Measured joint deviation exceeded the configured tracking limit.');
    end
    function validate_write(D,before,after)
        assert(isstruct(D)&&isscalar(D)&&all(isfield(D,{'sent_t','write_completed_t'})), ...
            'bpil:TransportWrite','write must return host send and completion timestamps.');
        validateattributes(D.sent_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        validateattributes(D.write_completed_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(D.sent_t>=before-1e-9&&D.write_completed_t>=D.sent_t&&D.write_completed_t<=after+1e-9, ...
            'bpil:TransportWrite','Write timestamps do not belong to this host call.');
    end
    function time_check(t)
        if t-R.started_t>O.max_time_s,error('bpil:TimeLimit','Session time limit reached.');end
    end
    function io_check(before,after,operation)
        if after-before>O.max_io_overrun_s
            error('bpil:IOOverrun','%s blocked for %.6f s; configured limit %.6f s.', ...
                operation,after-before,O.max_io_overrun_s);
        end
    end
    function event(kind,t)
        R.events{end+1}=struct('kind',kind,'time',t);
    end
    function close_once()
        if closed,return;end
        closed=true;
        try,T.close();catch e
            R.events{end+1}=struct('kind','close_error', ...
                'identifier',e.identifier,'message',e.message);
        end
    end
end
