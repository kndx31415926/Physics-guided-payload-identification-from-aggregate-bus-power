function [T,power_provider,inspect]=bpil_mock_hefting_transport(H,cfg,probe,options)
%BPIL_MOCK_HEFTING_TRANSPORT Deterministic virtual I/O for interface tests.
% No serial device or rigid-body plant is used. T102 instantly sets joint
% position, and power is synthesized from the static inverse model. This is
% a software-contract test fixture, never accuracy or physical evidence.
if nargin<4,options=struct();end
defaults=struct('feedback_delay_s',.006,'feedback_until',Inf, ...
    'power_until',Inf,'power_future_s',0,'power_fault_after_s',0, ...
    'power_calibrated',true,'power_offset_W',0,'power_nan',false, ...
    'tracking_offset_rad',zeros(1,4),'tracking_after_s',1, ...
    'write_delay_s',0,'write_delay_after_s',0,'wait_jitter_s',0, ...
    'torque_limits',[1000 1000 1000 1000 1000], ...
    'fixture_theta',[.15 .12 .005],'power_noise_W',.002, ...
    'initial_q',probe.poses(1,:),'power_clock_id',H.clock_id);
names=fieldnames(options);
for k=1:numel(names)
    assert(isfield(defaults,names{k}),'bpil:MockOption','Unknown mock option: %s',names{k});
    defaults.(names{k})=options.(names{k});
end
O=defaults;now=0;queue={};sent={};sent_times=[];write_times=[];
closed=false;close_count=0;fseq=0;wait_calls=0;poll_calls=0;power_calls=0;
q=O.initial_q;q_times=0;q_values=q;last_power_seq=-1;last_power=[];
cache_q=nan(1,4);cache_power=NaN;
T=struct('is_mock',true,'clock_id',H.clock_id,'now',@time,'poll',@poll, ...
    'write',@write_packet,'wait',@advance,'close',@close_it);
power_provider=@power_sample;inspect=@snapshot;
    function t=time(),t=now;end
    function advance(dt)
        validateattributes(dt,{'numeric'},{'scalar','finite','nonnegative'});
        wait_calls=wait_calls+1;now=now+max(dt,.001);
        if mod(wait_calls,7)==0,now=now+O.wait_jitter_s;end
    end
    function frames=poll()
        poll_calls=poll_calls+1;frames={};keep={};
        for j=1:numel(queue)
            if queue{j}.received_t<=now
                frames{end+1}=queue{j}; %#ok<AGROW>
            else
                keep{end+1}=queue{j}; %#ok<AGROW>
            end
        end
        queue=keep;
    end
    function D=write_packet(packet)
        a=jsondecode(packet);start=now;
        if now>=O.write_delay_after_s,now=now+O.write_delay_s;end
        sent{end+1}=a;sent_times(end+1)=start;write_times(end+1)=now;
        bytes=numel(unicode2native(packet,'UTF-8'));
        D=struct('sent_t',start,'write_completed_t',now, ...
            'acknowledged',false,'byte_count',bytes,'tx_lower_bound_s',10*bytes/H.baud_rate);
        if a.T==102
            wire=[a.base a.shoulder a.elbow a.hand];
            q=(wire-H.zero_offset_rad)./H.sign;
            q_times(end+1,1)=now;q_values(end+1,:)=q;
        elseif a.T==105&&start<=O.feedback_until
            fseq=fseq+1;measured=q;
            if start>=O.tracking_after_s,measured=measured+O.tracking_offset_rad;end
            wire=H.sign.*measured+H.zero_offset_rad;
            if strcmp(H.feedback_t_semantics,'wrist_tool_pitch')
                wire(4)=wire(4)+wire(2)+wire(3)-pi/2;
            end
            done=now+O.feedback_delay_s;
            span=min(.002,O.feedback_delay_s);
            f=struct('T',1051,'fver',2,'freq',a.rid,'fseq',fseq, ...
                'fmode',1,'fok',31,'ft0',mod(round((done-span)*1e6),2^32), ...
                'ft1',mod(round(done*1e6),2^32),'b',wire(1),'s',wire(2), ...
                'e',wire(3),'t',wire(4),'flim',O.torque_limits);
            queue{end+1}=struct('raw',jsonencode(f),'received_t',done);
        end
    end
    function p=power_sample(varargin) %#ok<INUSD>
        power_calls=power_calls+1;
        sample=max(0,min(now,floor(min(now,O.power_until)/.01)*.01));
        seq=round(sample/.01);
        if seq~=last_power_seq
            ix=find(q_times<=sample+1e-10,1,'last');sample_q=q_values(ix,:);
            if ~isequal(sample_q,cache_q)
                eta=struct('coefficients',cfg.legacy.power.coefficients);
                cache_power=bpil_predict_power(cfg,sample_q,O.fixture_theta,eta);cache_q=sample_q;
            end
            P=cache_power+O.power_noise_W*sin(seq*sqrt(2));
            if now>=O.power_fault_after_s,P=P+O.power_offset_W;end
            p=struct('Vin_V',12,'Iin_A',P/12,'sample_t',sample,'received_t',sample, ...
                'seq',seq,'clock_id',O.power_clock_id,'calibrated',true, ...
                'measurement_id','synthetic_static_power_mock', ...
                'scope','Mock software test; not a measured electrical signal');
            if now>=O.power_fault_after_s
                p.calibrated=O.power_calibrated;
                if O.power_future_s>0,p.sample_t=now+O.power_future_s;p.received_t=now;end
                if O.power_nan,p.Iin_A=NaN;end
            end
            last_power_seq=seq;last_power=p;
        else
            p=last_power;
        end
    end
    function close_it()
        if ~closed,closed=true;close_count=close_count+1;end
    end
    function s=snapshot()
        s=struct('time',now,'close_count',close_count,'sent',{sent}, ...
            'sent_times',sent_times,'write_times',write_times,'wait_calls',wait_calls, ...
            'poll_calls',poll_calls,'power_calls',power_calls,'q',q, ...
            'scope','Virtual I/O with exact position setting and synthetic static power; no hardware or physical validation');
    end
end
