function [T,inspect]=bpil_mock_arm_control_transport(H,options)
%BPIL_MOCK_ARM_CONTROL_TRANSPORT Virtual protocol fixture; no physical plant.
% Encoder states follow commands exactly unless a declared fault suppresses
% them. Tests establish software contracts, never dynamics or accuracy.
if nargin<2,options=struct();end
D=struct('telemetry','v2','initial_q',zeros(1,4), ...
    'feedback_delay_s',.006,'feedback_until_s',Inf,'fault_after_s',Inf, ...
    'reset_sequence',false,'read_ok_mask',31,'reported_mode',1, ...
    'wrong_request_id',false,'request_write_delay_s',0, ...
    'command_write_delay_s',0,'write_delay_after_s',0, ...
    'wait_jitter_s',0,'ignore_motion',false,'freeze_position_after_s',Inf, ...
    'torque_limits',[1000 1000 1000 1000 1000]);
names=fieldnames(options);
for k=1:numel(names)
    assert(isfield(D,names{k}),'test:ArmMockOption','Unknown mock option %s.',names{k});
    D.(names{k})=options.(names{k});
end
assert(any(strcmp(D.telemetry,{'stock','v2'})),'test:ArmMockTelemetry','Unknown telemetry.');
now=0;closed=false;close_count=0;poll_calls=0;wait_calls=0;request_count=0;
q=D.initial_q;queue={};sent={};sent_times=[];write_completed_times=[];
frames_delivered={};first_bad_frame_t=NaN;
sgn=H.nominal_sign;offset=H.nominal_zero_offset_rad;
if all(isfinite(H.sign)),sgn=H.sign;end
if all(isfinite(H.zero_offset_rad)),offset=H.zero_offset_rad;end
T=struct('now',@time,'poll',@poll,'write',@write_packet,'wait',@advance, ...
    'close',@close_it,'clock_id',H.clock_id,'is_mock',true);
inspect=@snapshot;
    function t=time(),t=now;end
    function frames=poll()
        assert(~closed,'test:ArmMockClosed','Poll after close.');
        poll_calls=poll_calls+1;frames={};keep={};
        for j=1:numel(queue)
            if queue{j}.received_t<=now+1e-12
                f=queue{j};frames{end+1}=f;frames_delivered{end+1}=f; %#ok<AGROW>
                if f.mock_fault&&isnan(first_bad_frame_t),first_bad_frame_t=now;end
            else
                keep{end+1}=queue{j}; %#ok<AGROW>
            end
        end
        queue=keep;
    end
    function W=write_packet(packet)
        assert(~closed,'test:ArmMockClosed','Write after close.');
        a=jsondecode(packet);start=now;
        assert(isstruct(a)&&isscalar(a)&&isfield(a,'T'),'test:ArmMockPacket','Invalid packet.');
        assert(any(a.T==[102 105]),'test:ArmForbiddenMutation', ...
            'Control interface attempted configuration/torque mutation T=%g.',a.T);
        delay=0;
        if start>=D.write_delay_after_s
            if a.T==105,delay=D.request_write_delay_s;else,delay=D.command_write_delay_s;end
        end
        now=now+delay;sent{end+1}=a;sent_times(end+1)=start;write_completed_times(end+1)=now;
        bytes=numel(unicode2native(packet,'UTF-8'));
        W=struct('sent_t',start,'write_completed_t',now,'acknowledged',false, ...
            'tx_start_estimate',start,'tx_end_estimate',max(now,start+10*bytes/H.baud_rate), ...
            'byte_count',bytes,'application_time_known',false);
        if a.T==102
            if ~D.ignore_motion&&start<D.freeze_position_after_s
                q=([a.base a.shoulder a.elbow a.hand]-offset)./sgn;
            end
            return
        end
        request_count=request_count+1;
        if start>D.feedback_until_s,return;end
        wire=sgn.*q+offset;
        if strcmp(H.feedback_t_semantics,'wrist_tool_pitch')
            wire(4)=wire(4)+wire(2)+wire(3)-pi/2;
        end
        aout=struct('T',1051,'b',wire(1),'s',wire(2),'e',wire(3),'t',wire(4));
        bad=start>=D.fault_after_s;
        done=now+D.feedback_delay_s;
        if strcmp(D.telemetry,'v2')
            rid=0;if isfield(a,'rid'),rid=a.rid;end
            seq=request_count;mask=31;mode=1;
            if bad
                if D.reset_sequence,seq=1;end
                mask=D.read_ok_mask;mode=D.reported_mode;
                if D.wrong_request_id,rid=rid+1000;end
            end
            aout.fver=2;aout.freq=rid;aout.fseq=seq;aout.fmode=mode;
            aout.fok=mask;aout.ft0=mod(round(max(0,done-.002)*1e6),2^32);
            aout.ft1=mod(round(done*1e6),2^32);
            if isfield(a,'lim')&&a.lim==1,aout.flim=D.torque_limits;end
        end
        queue{end+1}=struct('raw',jsonencode(aout),'received_t',done,'mock_fault',bad);
    end
    function advance(dt)
        assert(~closed,'test:ArmMockClosed','Wait after close.');
        validateattributes(dt,{'numeric'},{'scalar','real','finite','nonnegative'});
        wait_calls=wait_calls+1;now=now+max(dt,.001);
        if mod(wait_calls,7)==0,now=now+D.wait_jitter_s;end
    end
    function close_it()
        if ~closed,closed=true;close_count=close_count+1;end
    end
    function S=snapshot()
        S=struct('time',now,'closed',closed,'close_count',close_count, ...
            'poll_calls',poll_calls,'wait_calls',wait_calls,'sent',{sent}, ...
            'sent_times',sent_times,'write_completed_times',write_completed_times, ...
            'frames_delivered',{frames_delivered},'first_bad_frame_t',first_bad_frame_t, ...
            'q',q,'scope','Virtual protocol fixture; no robot or power source.');
    end
end
