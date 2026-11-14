function [obs,truth] = bpil_simulate_probe(cfg,payload,probe,drift,seed)
%BPIL_SIMULATE_PROBE Full v29 local PID and rigid-body dynamics, 1 ms steps.
% Default: fixed 20 ms command delay, not the original serial queue.
% Optional cfg.sim.communication models one-way command and encoder-return
% packet delays, without delaying the robot's local 1 ms PID feedback.
% Command/encoder: 20 Hz. Port power: 100 Hz. Encoder quantization: 4096/rev.
% q in the 100-Hz record is the most recent sampled noisy encoder value.
% obs contains only deployable readings, commands and observed summaries.
if nargin<4||isempty(drift),drift=struct();end
if nargin<5,seed=1;end
old=rng;cleanup=onCleanup(@()rng(old)); %#ok<NASGU>
rng(seed,'twister');cfg.drift=drift;
[model,C]=bpil_make_plant(cfg,payload);
dt=cfg.sim.dt;assert(abs(dt-.001)<1e-12,'bpil:TimeStep','Use the full 1 ms plant.');
poses=probe.poses;N=size(poses,1);assert(size(poses,2)==4&&N>=1,'bpil:Probe','Expected N-by-4 poses.');
move=cfg.sim.move_s;hold=cfg.sim.hold_s;initial=cfg.sim.initial_hold_s;
assert(move>0&&hold>=.2&&initial>0,'bpil:Timing','Positive move/initial hold and >=.2 s plateau required.');
duration=initial+N*(move+hold);steps=round(duration/dt);
command_stride=50;power_stride=10;delay_steps=20;
communication_enabled=isfield(cfg.sim,'communication');
if communication_enabled
    communication=bpil_communication_schedule(cfg.sim.communication,seed,dt,steps,command_stride);
    command_packet=0;encoder_packet=0;encoder_due=Inf;
    encoder_sample_t=0;encoder_receive_t=0;
end
quantum=2*pi/4096;qstart=poses(1,:);
st=bdclp_servo_init(qstart,zeros(1,4),C,model);
cmd=struct('q',round(qstart/quantum)*quantum,'speed',C.command.speed,'acc',C.command.acc,'issued_t',0,'seq',0);
issued=cmd;pending=cmd;due=Inf;
cap=floor(steps/power_stride);t=zeros(cap,1);q=zeros(cap,4);P=zeros(cap,1);qcmd=zeros(cap,4);
tq=zeros(cap,4);tdq=zeros(cap,4);ttau=zeros(cap,4);tP=zeros(cap,1);
if communication_enabled
    encoder_sample_record=zeros(cap,1);encoder_receive_record=zeros(cap,1);
end
qread=round((st.q+cfg.sensor.position_std_rad*randn(1,4))/quantum)*quantum;
if communication_enabled,initial_encoder_q=qread;end
reasons={};physical_ok=true;r=0;max_residual=0;
for k=1:steps
    now=(k-1)*dt;
    if mod(k-1,command_stride)==0
        target=reference(now,initial,move,hold,poses);
        issued=cmd;issued.q=round(target/quantum)*quantum;issued.issued_t=now;issued.seq=issued.seq+1;
        pending=issued;
        if communication_enabled
            command_packet=command_packet+1;
            delay_steps=communication.command_delay_steps(command_packet);
            communication.command_packets.q(command_packet,:)=issued.q;
        end
        due=k+delay_steps;
    end
    if k>=due
        cmd=pending;due=Inf;
        if communication_enabled,communication.command_packets.applied_t(command_packet)=now;end
    end
    [st,D]=bdclp_servo_step(st,cmd,model,C,dt);
    max_residual=max(max_residual,D.solver_residual_Nm);
    if ~D.pass
        physical_ok=false;reasons=unique([reasons,D.reasons],'stable');break;
    end
    if mod(k,command_stride)==0
        sampled_q=round((st.q+cfg.sensor.position_std_rad*randn(1,4))/quantum)*quantum;
        if communication_enabled
            encoder_packet=encoder_packet+1;
            encoder_pending_q=sampled_q;
            encoder_due=k+communication.encoder_delay_steps(encoder_packet);
            communication.encoder_packets.q(encoder_packet,:)=sampled_q;
        else
            qread=sampled_q;
        end
    end
    if communication_enabled&&k>=encoder_due
        qread=encoder_pending_q;encoder_due=Inf;
        encoder_sample_t=communication.encoder_packets.sample_t(encoder_packet);
        encoder_receive_t=k*dt;
        communication.encoder_packets.receive_t(encoder_packet)=encoder_receive_t;
    end
    if mod(k,power_stride)==0
        r=r+1;t(r)=k*dt;q(r,:)=qread;P(r)=D.Pin_W+cfg.sensor.power_std_W*randn;
        qcmd(r,:)=issued.q;tq(r,:)=st.q;tdq(r,:)=st.dq;ttau(r,:)=D.tau;tP(r)=D.Pin_W;
        if communication_enabled
            encoder_sample_record(r)=encoder_sample_t;encoder_receive_record(r)=encoder_receive_t;
        end
    end
end
t=t(1:r);q=q(1:r,:);P=P(1:r);qcmd=qcmd(1:r,:);
pq=nan(N,4);pp=nan(N,1);psd=nan(N,1);stationary=false(N,1);
true_speed=nan(N,1);true_dynamic=nan(N,1);window=min(.3,hold/2);
for n=1:N
    finish=initial+n*(move+hold);sel=t>=finish-window-1e-10&t<=finish+1e-10;
    if sum(sel)<max(10,round(window*80)),continue;end
    pq(n,:)=mean(q(sel,:),1);pp(n)=mean(P(sel));psd(n)=std(P(sel));
    samples=q(sel,:);delta=samples(end,:)-samples(1,:);
    stationary(n)=norm(delta)/window<.035&&max(max(samples,[],1)-min(samples,[],1))<.012;
    true_speed(n)=sqrt(mean(sum(tdq(sel,:).^2,2)));
    indices=find(sel);res=zeros(numel(indices),1);
    for j=1:numel(indices)
        ii=indices(j);g=gravityTorque(model.robot,tq(ii,:));
        res(j)=norm(ttau(ii,:)-g);
    end
    true_dynamic(n)=sqrt(mean(res.^2));
end
if ~all(stationary),reasons{end+1}='one_or_more_observed_plateaus_not_stationary';end
obs=struct('t',t,'q',q,'P',P,'q_command',qcmd,'plateau_q',pq,'plateau_P',pp, ...
    'plateau_sd_P',psd,'stationary',stationary,'probe_id',probe.id);
truth=struct('payload',model.metadata.bpil_payload,'drift',drift,'seed',seed, ...
    'success',physical_ok&&all(stationary),'physical_success',physical_ok,'reasons',{reasons}, ...
    't',t,'q',tq(1:r,:),'dq',tdq(1:r,:),'tau',ttau(1:r,:),'P',tP(1:r), ...
    'plateau_speed_rms_rad_s',true_speed,'plateau_dynamic_torque_rms_Nm',true_dynamic, ...
    'maximum_solver_residual_Nm',max_residual,'command_delay_s',.020, ...
    'scope','nominal PID/rigid-body plant; fixed command delay; uncalibrated hardware; cy unidentifiable from static data');
if communication_enabled
    % Timing truth is kept out of deployable observations: a real host has no
    % command-application ACK. Only arrived encoder packets are observable.
    received=isfinite(communication.encoder_packets.receive_t);
    sent=isfinite(communication.command_packets.q(:,1));
    obs.communication=struct('schema','bpil_observed_communication_v1', ...
        'command_issued_t',communication.command_packets.issued_t(sent), ...
        'command_q',communication.command_packets.q(sent,:), ...
        'encoder_packets',struct('sequence',communication.encoder_packets.sequence(received), ...
            'sample_t',communication.encoder_packets.sample_t(received), ...
            'receive_t',communication.encoder_packets.receive_t(received), ...
            'q',communication.encoder_packets.q(received,:)), ...
        'initial_encoder_sample_t',0,'initial_encoder_receive_t',0, ...
        'initial_encoder_q',initial_encoder_q, ...
        'power_record_encoder_sample_t',encoder_sample_record(1:r), ...
        'power_record_encoder_receive_t',encoder_receive_record(1:r));
    truth.communication=communication;
    if numel(unique(communication.command_delay_steps))==1
        truth.command_delay_s=communication.command_delay_steps(1)*dt;
    else
        truth.command_delay_s=NaN; % The delay is per packet, not a constant.
    end
    truth.scope=['PID/rigid-body plant; independent one-way command and encoder-return delays; ', ...
        'fixed 50 ms host issue/sample periods; local PID feedback unchanged; undelayed 100 Hz power; ', ...
        'uncalibrated hardware; cy unidentifiable from static data'];
end
end
function target=reference(t,initial,move,hold,poses)
if t<initial,target=poses(1,:);return;end
local=t-initial;n=min(size(poses,1),floor(local/(move+hold))+1);
phase=local-(n-1)*(move+hold);previous=poses(max(1,n-1),:);
x=max(0,min(1,phase/move));blend=10*x^3-15*x^4+6*x^5;
target=previous+blend*(poses(n,:)-previous);
end
