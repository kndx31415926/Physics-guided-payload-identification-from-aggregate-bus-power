function [obs,state]=bdclp_decode_feedback(raw,received_t,H,state,transport,power)
%BDCLP_DECODE_FEEDBACK Decode measurements; shared observer owns dq/Pavg.
% For extended fver=2 telemetry, transport supplies host request_t/request_id.
% MCU micros values only bound acquisition duration, never become host time.
if nargin<4||isempty(state),state=struct();end
if nargin<5,transport=struct();end
if nargin<6,power=struct();end
validateattributes(received_t,{'numeric'},{'scalar','finite','nonnegative'});
if ischar(raw)||(isstring(raw)&&isscalar(raw)),raw=jsondecode(char(raw));end
assert(isstruct(raw)&&isscalar(raw)&&isfield(raw,'T')&&isequal(raw.T,1051), ...
    'bdclp:FeedbackFrame','Expected a raw T1051 frame.');
fields={'b','s','e','t'};wire=zeros(1,4);
for j=1:4
    assert(isfield(raw,fields{j}),'bdclp:FeedbackFrame','Missing position field.');
    validateattributes(raw.(fields{j}),{'numeric'},{'scalar','real','finite'});
    wire(j)=raw.(fields{j});
end
if strcmp(H.feedback_t_semantics,'wrist_tool_pitch')&&strcmp(H.ee_mode,'wrist')
    wire(4)=wire(4)-wire(2)-wire(3)+pi/2;
elseif ~strcmp(H.feedback_t_semantics,'joint_angle')
    error('bdclp:FeedbackSemantics','Configure measured fourth-angle semantics.');
end
q=(wire-H.zero_offset_rad)./H.sign;
bdclp_encode_command(struct('q',q,'speed',1,'acc',1),H,'hardware');
obs=struct('t',received_t,'received_t',received_t,'q',q,'dq',nan(1,4), ...
    'sample_t',NaN,'sample_time_window_s',[NaN NaN],'sample_time_exact',false, ...
    'position_fresh',false,'velocity_valid',false,'power_valid',false, ...
    'usable_for_control',false,'Pin_W',NaN,'Pdraw_W',NaN,'Vin_V',NaN, ...
    'Iin_A',NaN,'Pavg_W',NaN,'power_sample_t',NaN,'reasons',{{}}, ...
    'position_sample',[],'power_sample',[],'device_sequence',NaN, ...
    'torque_limit_register',[]);
required={'request_t','request_id','clock_id'};
complete=all(isfield(transport,required));
if complete
    validateattributes(transport.request_t,{'numeric'},{'scalar','finite','nonnegative','<=',received_t});
    validateattributes(transport.request_id,{'numeric'},{'scalar','finite','integer','nonnegative'});
    same_clock=strcmp(transport.clock_id,H.clock_id);
    increasing=~isfield(state,'last_request_id')||transport.request_id>state.last_request_id;
    time_increasing=~isfield(state,'received_t')||received_t>state.received_t;
    within_age=received_t-transport.request_t<=H.max_feedback_age_s;
    correlated=false;readok=false(1,4);device_seq=transport.request_id;
    telemetry_ok=false;
    if all(isfield(raw,{'fver','freq','fseq','fmode','fok','ft0','ft1'}))
        validateattributes(raw.fseq,{'numeric'},{'scalar','integer','>=',1,'<=',2^32-1});
        validateattributes(raw.freq,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
        device_seq=raw.fseq;obs.device_sequence=device_seq;
        if raw.fver==2
            validateattributes(raw.fok,{'numeric'},{'scalar','integer','>=',0,'<=',31});
            ok=logical(bitget(uint32(raw.fok),1:5));
            validateattributes(raw.ft0,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
            validateattributes(raw.ft1,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
            span=mod(double(raw.ft1)-double(raw.ft0),2^32)*1e-6;
            telemetry_ok=span<=H.max_acquisition_span_s;
        elseif raw.fver==1
            ok=reshape(raw.fok,1,[]);t0=reshape(double(raw.ft0),1,[]);t1=reshape(double(raw.ft1),1,[]);
            assert(numel(ok)==5&&all(ismember(ok,[0 1]))&&numel(t0)==5&&numel(t1)==5, ...
                'bdclp:FeedbackStatus','Invalid version-one acquisition arrays.');
            a=[t0 t1];assert(all(isfinite(a))&&all(a>=0)&all(a<2^32)&&all(fix(a)==a), ...
                'bdclp:FeedbackStatus','Invalid device timestamp.');
            o0=mod(t0-t0(1),2^32);o1=mod(t1-t0(1),2^32);
            telemetry_ok=all(o1>=o0)&&all(o0(2:end)>=o1(1:end-1))&&o1(end)*1e-6<=H.max_acquisition_span_s;
        else
            ok=false(1,5);
        end
        mode_ok=(strcmp(H.ee_mode,'wrist')&&raw.fmode==1)||(strcmp(H.ee_mode,'gripper')&&raw.fmode==0);
        readok=[ok(1),ok(2)&&ok(3),ok(4),ok(5)];
        correlated=raw.freq==transport.request_id&&telemetry_ok&&mode_ok;
        increasing=increasing&&(~isfield(state,'last_device_seq')||device_seq>state.last_device_seq);
        if isfield(raw,'flim')
            lim=reshape(double(raw.flim),1,[]);
            if numel(lim)==5&&all(isfinite(lim))&&all(lim>=0)&&all(lim<=1000)&&all(fix(lim)==lim)
                obs.torque_limit_register=lim;
            end
        end
    elseif all(isfield(transport,{'request_correlated','servo_read_ok'}))
        % Explicit independently verified acquisition source; standard JSON
        % reception by itself does not supply these flags.
        assert(isequal(size(transport.servo_read_ok),[1 4])&&all(ismember(transport.servo_read_ok,[0 1])), ...
            'bdclp:FeedbackStatus','Four verified servo read flags are required.');
        readok=logical(transport.servo_read_ok);correlated=isequal(transport.request_correlated,true);
    end
    obs.sample_t=transport.request_t;
    obs.sample_time_window_s=[transport.request_t received_t];
    obs.position_fresh=H.position_source_verified&&same_clock&&increasing&&time_increasing&&within_age&&correlated&&all(readok);
    if ~same_clock,obs.reasons{end+1}='clock_mismatch';end
    if ~increasing||~time_increasing,obs.reasons{end+1}='duplicate_or_reset_or_out_of_order';end
    if ~within_age,obs.reasons{end+1}='stale_response';end
    if ~all(readok),obs.reasons{end+1}='servo_read_failed_or_cached';end
    if ~correlated,obs.reasons{end+1}='uncorrelated_or_unverified_response';end
    obs.position_sample=struct('kind','position','q',q,'sample_t',obs.sample_t, ...
        'received_t',received_t,'seq',device_seq,'valid',obs.position_fresh);
else
    obs.reasons{end+1}='missing_acquisition_status';
end
if ~H.position_source_verified,obs.reasons{end+1}='position_source_not_verified';end
if ~isempty(fieldnames(power))
    req={'Vin_V','Iin_A','sample_t','seq','clock_id','calibrated','measurement_id'};
    assert(all(isfield(power,req)),'bdclp:PowerMeasurement','Incomplete input-port measurement.');
    validateattributes(power.Vin_V,{'numeric'},{'scalar','finite','positive'});
    validateattributes(power.Iin_A,{'numeric'},{'scalar','finite','real'});
    validateattributes(power.sample_t,{'numeric'},{'scalar','finite','nonnegative','<=',received_t});
    obs.Vin_V=power.Vin_V;obs.Iin_A=power.Iin_A;obs.Pin_W=power.Vin_V*power.Iin_A;
    obs.Pdraw_W=max(obs.Pin_W,0);obs.power_sample_t=power.sample_t;
    obs.power_valid=isequal(power.calibrated,true)&&~isempty(power.measurement_id)&& ...
        strcmp(power.clock_id,H.clock_id)&&received_t-power.sample_t<=H.max_power_age_s;
    obs.power_sample=struct('kind','power','Vin_V',power.Vin_V,'Iin_A',power.Iin_A, ...
        'Pin_W',obs.Pin_W,'sample_t',power.sample_t,'received_t',received_t, ...
        'seq',power.seq,'valid',obs.power_valid);
end
if obs.position_fresh
    state.last_request_id=transport.request_id;state.last_device_seq=device_seq;state.received_t=received_t;
end
% No velocity or power averaging here. Both hardware and simulation must call
% bdclp_observation_update on the returned samples and request a snapshot.
end
