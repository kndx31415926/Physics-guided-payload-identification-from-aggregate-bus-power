function R=bpil_hefting_loop(T,power_provider,H,cfg,probe,options)
%BPIL_HEFTING_LOOP Fixed 20-Hz probe with independent measured bus power.
% All clocks belong to T. A position's sample_t is the request-time lower
% bound, not an invented exact acquisition time. No fitting/training runs in
% this loop. A late host holds the last target and stretches reference time;
% elapsed reference increments are never sent in a catch-up burst.
if nargin<6,options=struct();end
defaults=struct('max_time_s',45,'stop_requested',@()false, ...
    'max_tracking_error_rad',.20,'max_power_W',Inf,'max_io_overrun_s',.10, ...
    'final_position_tolerance_rad',.01,'final_stationary_duration_s',.15);
if isfield(H,'max_power_W'),defaults.max_power_W=H.max_power_W;end
names=fieldnames(defaults);
for k=1:numel(names)
    if ~isfield(options,names{k}),options.(names{k})=defaults.(names{k});end
end
R=struct('schema','bpil_hefting_hardware_session_v1','completed',false, ...
    'reason','time_limit','error_message','','raw_positions',{{}}, ...
    'raw_power',{{}},'commands',{{}},'decisions',{{}},'events',{{}}, ...
    'started_t',NaN,'motion_start_t',NaN,'initial_hold_end_t',NaN, ...
    'terminal_command_t',NaN,'ended_t',NaN,'control_period_s',.05, ...
    'hardware_opened',false,'hardware_validated',false,'is_mock',T.is_mock, ...
    'torque_limits_verified',false,'torque_disabled_on_exit',false, ...
    'clock_id',H.clock_id,'hardware_timing_measured',~T.is_mock, ...
    'application_times_estimated',true,'reference_duration_s',NaN, ...
    'exit_action','Stop sending; retain the last position target and leave servo torque state unchanged.');
cleanup=onCleanup(@safe_close); %#ok<NASGU>
last_clock=-Inf;last_power=[];last_position=[];pending=[];decoder_state=[];
last_request_id=0;last_request_sent=-Inf;last_command_sent=-Inf;
limits_verified=false;next_reference=0;command_count=0;power_identity='';
initial=cfg.sim.initial_hold_s;move=cfg.sim.move_s;hold=cfg.sim.hold_s;
poses=probe.poses;duration=initial+size(poses,1)*(move+hold);
period=.05;next_command=Inf;terminal_sent=NaN;final_stable_since=NaN;final_last_seq=NaN;
try
    validateattributes(options.max_time_s,{'numeric'},{'scalar','real','finite','positive'});
    validateattributes(options.max_tracking_error_rad,{'numeric'},{'scalar','real','finite','positive'});
    validateattributes(options.max_power_W,{'numeric'},{'scalar','real','positive'});
    validateattributes(options.max_io_overrun_s,{'numeric'},{'scalar','real','finite','positive'});
    validateattributes(options.final_position_tolerance_rad,{'numeric'},{'scalar','real','finite','positive'});
    validateattributes(options.final_stationary_duration_s,{'numeric'},{'scalar','real','finite','positive'});
    assert(isa(options.stop_requested,'function_handle'),'bpil:StopCallback','stop_requested must be a function handle.');
    assert(abs(H.control_dt_s-period)<1e-12,'bpil:ControlPeriod','The external control period must be 50 ms.');
    assert(strcmp(T.clock_id,H.clock_id),'bpil:ClockMismatch','Transport and profile clock identities differ.');
    validateattributes(poses,{'numeric'},{'2d','real','finite','ncols',4,'nonempty'});
    assert(initial>0&&move>0&&hold>=.2,'bpil:ProbeTiming','Probe timing is invalid.');
    R.reference_duration_s=duration;R.started_t=now_s();
    if H.allow_torque_limit_write
        [packet,~]=bdclp_wire_packet('wrist_limit',struct('limit',H.required_torque_limit_register(4)),H,'hardware');
        before=now_s();D=T.write(packet);after=now_s();validate_write(D,before,after);
        R.events{end+1}=struct('kind','wrist_limit_write','time',D.sent_t, ...
            'packet',packet,'register_value',H.required_torque_limit_register(4), ...
            'readback_verified',false,'acknowledged',false);
        io_check(before,after,'wrist_limit_write');
    end
    while now_s()-R.started_t<=options.max_time_s
        stop=options.stop_requested();
        assert(islogical(stop)&&isscalar(stop),'bpil:StopCallback','stop_requested must return a scalar logical.');
        if stop,R.reason='stopped_by_user';break;end
        before=now_s();powers=power_provider(before);after=now_s();
        if isstruct(powers),powers=num2cell(powers);end
        assert(isempty(powers)||iscell(powers),'bpil:PowerProvider','Power provider must return structs, a cell array, or empty.');
        for k=1:numel(powers)
            try,accept_power(powers{k});catch e
                R.events{end+1}=struct('kind','rejected_power_sample','time',last_clock,'sample',powers{k},'identifier',e.identifier);
                rethrow(e);
            end
        end
        io_check(before,after,'power_provider');
        before=now_s();frames=T.poll();after=now_s();
        assert(iscell(frames),'bpil:TransportPoll','Transport poll must return a cell array.');
        for k=1:numel(frames)
            try,accept_position(frames{k});catch e
                R.events{end+1}=struct('kind','rejected_position_frame','time',last_clock,'frame',frames{k},'identifier',e.identifier);
                rethrow(e);
            end
        end
        io_check(before,after,'position_poll');
        now=now_s();
        if now-R.started_t>options.max_time_s,R.reason='time_limit';break;end
        if ~isempty(pending)&&now-pending.request_t>H.request_timeout_s
            error('bpil:FeedbackTimeout','The pending feedback request exceeded %.3f s.',H.request_timeout_s);
        end
        if isnan(R.motion_start_t)
            if now-R.started_t>H.startup_timeout_s
                error('bpil:HardwareStartup','No verified position, torque-limit readback and fresh bus-power observation before startup timeout.');
            end
        else
            assert_fresh(now);
            if max(abs(last_position.q-R.commands{end}.q))>options.max_tracking_error_rad
                error('bpil:TrackingError','Measured joint deviation from the last issued target exceeded the configured limit.');
            end
        end
        if ~isempty(last_power)&&abs(last_power.Pin_W)>options.max_power_W
            error('bpil:PowerLimit','Measured absolute bus power exceeded the configured limit.');
        end
        % Requests also obey start-to-start 50-ms spacing. A missing reply
        % never causes another request to overwrite its correlation record.
        if isempty(pending)&&now-last_request_sent>=period-1e-12
            last_request_id=last_request_id+1;
            data=struct('request_id',last_request_id,'read_limits',~limits_verified);
            [packet,~]=bdclp_wire_packet('position_request',data,H,'hardware');
            before=now_s();D=T.write(packet);after=now_s();validate_write(D,before,after);
            assert(D.sent_t-last_request_sent>=period-1e-12,'bpil:RequestCadence','Request starts are less than 50 ms apart.');
            pending=struct('request_t',D.sent_t,'request_id',last_request_id,'clock_id',H.clock_id);
            last_request_sent=D.sent_t;
            R.events{end+1}=struct('kind','position_request','time',D.sent_t, ...
                'request_id',last_request_id,'read_limits',~limits_verified, ...
                'packet',packet,'write_completed_t',D.write_completed_t);
            io_check(before,after,'position_request');
        end
        now=now_s();
        if isnan(R.motion_start_t)&&limits_verified&&fresh_position(now)&&fresh_power(now)
            assert(max(abs(last_position.q-poses(1,:)))<=min(.05,H.start_position_tolerance_rad), ...
                'bpil:InitialPose','Pre-position the arm at the first probe pose; this loop does not move to the start automatically.');
            next_command=now;
        end
        if now>=next_command&&isnan(terminal_sent)
            stop=options.stop_requested();
            assert(islogical(stop)&&isscalar(stop),'bpil:StopCallback','stop_requested must return a scalar logical.');
            if stop,R.reason='stopped_by_user';break;end
            now=now_s();
            scheduled=next_command;assert_fresh(now);
            target=reference(next_reference,initial,move,hold,poses);
            if max(abs(last_position.q-target))>options.max_tracking_error_rad
                error('bpil:TrackingError','The next target exceeds the configured measured-position tracking limit.');
            end
            cmd=struct('q',target,'speed',cfg.legacy.command.speed,'acc',cfg.legacy.command.acc);
            [packet,W]=bdclp_encode_command(cmd,H,'hardware');
            before=now_s();D=T.write(packet);after=now_s();validate_write(D,before,after);
            D.packet=packet;D.q=target;D.reference_t=next_reference;
            D.acknowledged=false;D.application_time_estimated=true;
            D.byte_count=W.byte_count;D.wire_duration_s=W.tx_lower_bound_s;
            if ~isfield(D,'tx_start_estimate'),D.tx_start_estimate=D.sent_t;end
            if ~isfield(D,'tx_end_estimate')
                D.tx_end_estimate=D.tx_start_estimate+W.tx_lower_bound_s;
            end
            D.tx_end_estimate=max(D.tx_end_estimate,D.write_completed_t);
            D.applied_estimate=D.tx_end_estimate+cfg.legacy.transport.command_processing_s;
            D.processing_s=cfg.legacy.transport.command_processing_s;
            R.commands{end+1}=D;
            R.decisions{end+1}=struct('scheduled_t',scheduled,'decision_start_t',before, ...
                'decision_end_t',after,'reference_t',next_reference,'q',target, ...
                'position_sample_t',last_position.sample_t,'position_received_t',last_position.received_t, ...
                'power_sample_t',last_power.sample_t,'power_received_t',last_power.received_t, ...
                'sent_t',D.sent_t,'write_completed_t',D.write_completed_t, ...
                'late_s',max(0,D.sent_t-scheduled),'skipped_busy_ticks',max(0,floor((D.sent_t-scheduled)/period)), ...
                'accepted',true,'acknowledged',false);
            assert(D.sent_t-last_command_sent>=period-1e-12,'bpil:CommandCadence','Command starts are less than 50 ms apart.');
            if isnan(R.motion_start_t),R.motion_start_t=D.sent_t;end
            if isnan(R.initial_hold_end_t)&&next_reference>=initial-1e-12,R.initial_hold_end_t=D.sent_t;end
            last_command_sent=D.sent_t;next_command=D.sent_t+period;
            command_count=command_count+1;
            if next_reference>=duration-1e-12
                terminal_sent=D.sent_t;R.terminal_command_t=terminal_sent;
                next_command=Inf;
            else
                next_reference=min(duration,command_count*period);
            end
            % Record a write that already reached the transport even if its
            % host call was too slow; it cannot truthfully be called unsent.
            io_check(before,after,'position_command');
        end
        if ~isnan(terminal_sent)&&~isempty(last_position)&&last_position.sample_t>=terminal_sent ...
                &&last_position.seq~=final_last_seq
            final_last_seq=last_position.seq;
            if max(abs(last_position.q-poses(end,:)))<=options.final_position_tolerance_rad
                if isnan(final_stable_since),final_stable_since=last_position.sample_t;end
            else
                final_stable_since=NaN;
            end
            if ~isnan(final_stable_since)&&last_position.sample_t-final_stable_since>=options.final_stationary_duration_s ...
                    &&~isempty(last_power)&&last_power.sample_t>=last_position.sample_t
                R.completed=true;R.reason='completed';break;
            end
        end
        T.wait(H.poll_pause_s);
    end
catch e
    R.reason=e.identifier;R.error_message=e.message;
    R.events{end+1}=struct('kind','abort','time',last_clock,'identifier',e.identifier,'message',e.message);
end
R.torque_limits_verified=limits_verified;
R.final_position_confirmed=R.completed;
R.final_position_tolerance_rad=options.final_position_tolerance_rad;
R.final_stationary_duration_s=options.final_stationary_duration_s;
R.final_stable_since_t=final_stable_since;
try,R.ended_t=now_s();catch,R.ended_t=last_clock;end
if ~isempty(last_position),R.last_position_received_t=last_position.received_t;else,R.last_position_received_t=NaN;end
if ~isempty(last_power),R.last_power_received_t=last_power.received_t;else,R.last_power_received_t=NaN;end
try,T.close();catch e,R.events{end+1}=struct('kind','close_error','identifier',e.identifier,'message',e.message);end

    function t=now_s()
        t=T.now();
        validateattributes(t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(t>=last_clock,'bpil:ClockOrder','The transport clock moved backwards.');last_clock=t;
    end
    function accept_power(p)
        req={'Vin_V','Iin_A','sample_t','received_t','seq','clock_id','calibrated','measurement_id'};
        assert(isstruct(p)&&isscalar(p)&&all(isfield(p,req)),'bpil:PowerProvider','An input-port sample is incomplete.');
        try
            validateattributes(p.Vin_V,{'numeric'},{'scalar','real','finite','positive'});
            validateattributes(p.Iin_A,{'numeric'},{'scalar','real','finite'});
            validateattributes(p.sample_t,{'numeric'},{'scalar','real','finite','nonnegative'});
            validateattributes(p.received_t,{'numeric'},{'scalar','real','finite','nonnegative'});
            validateattributes(p.seq,{'numeric'},{'scalar','real','finite','integer','nonnegative'});
        catch invalid
            error('bpil:PowerProvider','Invalid input-port numeric measurement: %s',invalid.message);
        end
        assert((ischar(p.clock_id)||(isstring(p.clock_id)&&isscalar(p.clock_id)))&&strcmp(p.clock_id,H.clock_id), ...
            'bpil:ClockMismatch','Power measurement must use the transport clock identity.');
        assert(isequal(p.calibrated,true)&&(ischar(p.measurement_id)||(isstring(p.measurement_id)&&isscalar(p.measurement_id)))&&strlength(string(p.measurement_id))>0, ...
            'bpil:PowerProvider','Power must have a calibrated, identified measurement source.');
        assert(p.sample_t<=p.received_t&&p.received_t<=now_s()+1e-9, ...
            'bpil:FutureObservation','Power timestamps are in the future or precede acquisition.');
        if isempty(power_identity),power_identity=char(p.measurement_id);end
        assert(strcmp(power_identity,p.measurement_id),'bpil:PowerSourceChanged','Power measurement source changed during the session.');
        p=struct('kind','power','Vin_V',p.Vin_V,'Iin_A',p.Iin_A, ...
            'sample_t',p.sample_t,'received_t',p.received_t,'seq',p.seq, ...
            'clock_id',char(p.clock_id),'calibrated',p.calibrated, ...
            'measurement_id',char(p.measurement_id),'Pin_W',p.Vin_V*p.Iin_A, ...
            'Pdraw_W',max(p.Vin_V*p.Iin_A,0),'valid',true);
        assert(isfinite(p.Pin_W),'bpil:PowerProvider','Input-port voltage/current product is not finite.');
        if ~isempty(last_power)&&(p.seq<=last_power.seq||p.sample_t<=last_power.sample_t||p.received_t<last_power.received_t)
            p.valid=false;
            R.events{end+1}=struct('kind','ignored_power_duplicate_or_out_of_order','time',now_s(),'sample',p);
            return;
        end
        R.raw_power{end+1}=p;last_power=p;
    end
    function accept_position(f)
        assert(isstruct(f)&&isscalar(f)&&all(isfield(f,{'raw','received_t'})), ...
            'bpil:TransportFrame','Transport returned an incomplete frame.');
        validateattributes(f.received_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(f.received_t<=now_s()+1e-9,'bpil:FutureObservation','Position receipt is in the future.');
        try,a=jsondecode(char(f.raw));catch
            R.events{end+1}=struct('kind','ignored_non_json_frame','time',f.received_t,'raw',f.raw);return;
        end
        if ~isstruct(a)||~isscalar(a)||~isfield(a,'T')||~isequal(a.T,1051)
            R.events{end+1}=struct('kind','ignored_unrelated_frame','time',f.received_t,'raw',f.raw);return;
        end
        if isempty(pending)||~isfield(a,'freq')||~isequal(a.freq,pending.request_id)
            R.events{end+1}=struct('kind','ignored_uncorrelated_position','time',f.received_t,'raw',f.raw);return;
        end
        assert(isfield(a,'fver')&&isequal(a.fver,2),'bpil:TelemetryVersion','A request-correlated compact v2 telemetry frame is required.');
        [obs,decoded]=bdclp_decode_feedback(a,f.received_t,H,decoder_state,pending);
        p=obs.position_sample;p.clock_id=H.clock_id;p.sample_time_window_s=obs.sample_time_window_s;
        p.sample_time_exact=false;p.sample_t_is_request_lower_bound=true;p.request_id=pending.request_id;
        p.raw=f.raw;p.torque_limit_register=obs.torque_limit_register;
        R.raw_positions{end+1}=p;
        assert(obs.position_fresh,'bpil:InvalidFeedback','Servo feedback failed acquisition, freshness, order, or source verification.');
        decoder_state=decoded;last_position=p;pending=[];
        if ~isempty(obs.torque_limit_register)
            wanted=H.required_torque_limit_register([1 2 2 3 4]);
            assert(isequal(obs.torque_limit_register,wanted),'bpil:TorqueLimitReadback', ...
                'Measured torque-limit registers differ from the hardware profile.');
            if ~limits_verified
                R.events{end+1}=struct('kind','torque_limit_readback','time',f.received_t, ...
                    'register_value',obs.torque_limit_register,'readback_verified',true);
            end
            limits_verified=true;
        end
    end
    function yes=fresh_position(t)
        yes=~isempty(last_position)&&last_position.valid&&t-last_position.sample_t<=H.max_feedback_age_s&&last_position.received_t<=t;
    end
    function yes=fresh_power(t)
        yes=~isempty(last_power)&&last_power.valid&&t-last_power.sample_t<=H.max_power_age_s&&last_power.received_t<=t;
    end
    function assert_fresh(t)
        assert(fresh_position(t),'bpil:StalePosition','A verified position sample is unavailable or older than the configured %.3f s limit.',H.max_feedback_age_s);
        assert(fresh_power(t),'bpil:StalePower','A measured power sample is unavailable or older than the configured %.3f s limit.',H.max_power_age_s);
    end
    function validate_write(D,before,after)
        assert(isstruct(D)&&isscalar(D)&&all(isfield(D,{'sent_t','write_completed_t'})), ...
            'bpil:TransportWrite','Transport write must return host send and completion timestamps.');
        validateattributes(D.sent_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        validateattributes(D.write_completed_t,{'numeric'},{'scalar','real','finite','nonnegative'});
        assert(D.sent_t>=before-1e-9&&D.write_completed_t>=D.sent_t&&D.write_completed_t<=after+1e-9, ...
            'bpil:TransportWrite','Transport write timestamps do not belong to this host call.');
        for item={'tx_start_estimate','tx_end_estimate'}
            if isfield(D,item{1}),validateattributes(D.(item{1}),{'numeric'},{'scalar','real','finite','nonnegative'});end
        end
    end
    function io_check(before,after,operation)
        if after-before>options.max_io_overrun_s
            error('bpil:IOOverrun','%s blocked for %.6f s (configured limit %.6f s).',operation,after-before,options.max_io_overrun_s);
        end
    end
    function safe_close()
        try,T.close();catch,end
    end
end

function target=reference(t,initial,move,hold,poses)
if t<initial,target=poses(1,:);return;end
local=t-initial;n=min(size(poses,1),floor(local/(move+hold))+1);
phase=local-(n-1)*(move+hold);previous=poses(max(1,n-1),:);
x=max(0,min(1,phase/move));blend=10*x^3-15*x^4+6*x^5;
target=previous+blend*(poses(n,:)-previous);
end
