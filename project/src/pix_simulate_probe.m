function [obs,truth]=pix_simulate_probe(cfg,payload,probe,condition,sensorSeed,communication,S)
%PIX_SIMULATE_PROBE Independent actuator/electrical path, observable interface.
% Commands and encoders at 20 Hz; aggregate power at 100 Hz. ODE15s is
% restarted only at command-arrival discontinuities. deval evaluates its
% continuous numerical solution; no commanded states replace actual states.
% This function performs one episode, never training, scheduling or hardware.
% All intended randomness uses local streams; isolate incidental toolbox RNG.
caller_rng=rng;rng_cleanup=onCleanup(@()rng(caller_rng)); %#ok<NASGU>
if nargin<7||isempty(S),S=pix_config(cfg);end
if nargin<6||isempty(communication)
    communication=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015], ...
        'seed',mod(double(sensorSeed)+100000,2^32));
end
validateattributes(sensorSeed,{'numeric'},{'scalar','integer','>=',0,'<',2^32});
assert(strcmp(condition.schema,'pix_condition_v1'),'pix:Condition','Expected an explicit PIX condition.');
poses=double(probe.poses);assert(size(poses,2)==4&&size(poses,1)>=1&&all(isfinite(poses),'all'),'pix:Probe','Invalid probe.');
move=cfg.sim.move_s;hold=cfg.sim.hold_s;initial=cfg.sim.initial_hold_s;
assert(move>0&&hold>=.2&&initial>0,'pix:Timing','Invalid probe timing.');
duration=initial+size(poses,1)*(move+hold);
assert(duration<=30,'pix:Scope','Single-probe function is limited to 30 seconds of simulated time.');
assert(abs(duration/S.delay_grid_s-round(duration/S.delay_grid_s))<1e-8,'pix:Timing','Duration must lie on the declared timing grid.');
model=pix_make_plant(cfg,payload,condition,S);
assert(all(poses>=model.qmin&poses<=model.qmax,'all'),'pix:JointRange','Probe exceeds model joint limits.');
% Reuse only the study's packet-delay sampler, not its plant or loss model.
schedule=bpil_communication_schedule(communication,sensorSeed,S.delay_grid_s, ...
    round(duration/S.delay_grid_s),round(S.command_period_s/S.delay_grid_s));
for j=1:numel(schedule.command_packets.issued_t)
    schedule.command_packets.q(j,:)=round(reference(schedule.command_packets.issued_t(j))/S.quantum_rad)*S.quantum_rad;
end
apply=schedule.command_packets.scheduled_apply_t;
edges=unique([0;apply(apply>0&apply<duration);duration]);
sample_t=(S.dt_record_s:S.dt_record_s:duration).';
states=nan(numel(sample_t),28);x0=[poses(1,:) zeros(1,12) condition.initial_temperature_C zeros(1,8)].';
x=x0;initial_energy=pix_energy(model,x0);last_t=0;rhs_calls=0;segments=0;
reasons={};physical_ok=true;integration_error=[];
opts=odeset('RelTol',S.rel_tol,'AbsTol',S.abs_tol,'MaxStep',S.max_step_s,'Events',@bounds);
try
    for j=1:numel(edges)-1
        active=find(apply<=edges(j)+1e-12,1,'last');
        if isempty(active),command=round(poses(1,:)/S.quantum_rad)*S.quantum_rad;
        else,command=schedule.command_packets.q(active,:);end
        sol=ode15s(@rhs,[edges(j) edges(j+1)],x,opts);segments=segments+1;
        finish=sol.x(end);ix=sample_t>edges(j)+1e-10&sample_t<=finish+1e-10;
        if any(ix),states(ix,:)=deval(sol,min(sample_t(ix),finish)).';end
        x=sol.y(:,end);last_t=finish;
        if finish<edges(j+1)-1e-9
            physical_ok=false;reasons{end+1}='integration_stopped_at_state_boundary';break
        end
    end
catch err
    physical_ok=false;reasons{end+1}='ode_exception';
    integration_error=struct('identifier',err.identifier,'message',err.message,'stack',err.stack);
end
valid=all(isfinite(states),2);sample_t=sample_t(valid);states=states(valid,:);n=numel(sample_t);
rs=RandStream('mt19937ar','Seed',double(sensorSeed));
q0read=round((poses(1,:)+cfg.sensor.position_std_rad*randn(rs,1,4))/S.quantum_rad)*S.quantum_rad;
enc_t=schedule.encoder_packets.sample_t;sampled=enc_t<=last_t+1e-10;
for j=find(sampled).'
    ix=find(abs(sample_t-enc_t(j))<1e-9,1);
    assert(~isempty(ix),'pix:SampleGrid','Missing native encoder sample on common record grid.');
    schedule.encoder_packets.q(j,:)=round((states(ix,1:4)+cfg.sensor.position_std_rad*randn(rs,1,4))/S.quantum_rad)*S.quantum_rad;
end
received=sampled&schedule.encoder_packets.scheduled_receive_t<=last_t+1e-10;
schedule.encoder_packets.receive_t(received)=schedule.encoder_packets.scheduled_receive_t(received);
applied=apply<=last_t+1e-10;schedule.command_packets.applied_t(applied)=apply(applied);
qread=zeros(n,4);qcommand=zeros(n,4);P=zeros(n,1);tau=zeros(n,4);power_residual=zeros(n,1);
encoder_sample_t=zeros(n,1);encoder_receive_t=zeros(n,1);voltage=zeros(n,4);
power_parts=zeros(n,8);
for j=1:n
    t=sample_t(j);ei=find(received&schedule.encoder_packets.receive_t<=t+1e-12,1,'last');
    if isempty(ei),qread(j,:)=q0read;
    else
        qread(j,:)=schedule.encoder_packets.q(ei,:);
        encoder_sample_t(j)=enc_t(ei);encoder_receive_t(j)=schedule.encoder_packets.receive_t(ei);
    end
    % Sample precedes a simultaneous host issue; an arrived command affects
    % the instantaneous electrical sample after its stated arrival.
    issue=find(schedule.command_packets.issued_t<t-1e-12,1,'last');
    if isempty(issue),issue=1;end
    qcommand(j,:)=schedule.command_packets.q(issue,:);
    ai=find(apply<=t+1e-12,1,'last');
    if isempty(ai),cmd=round(poses(1,:)/S.quantum_rad)*S.quantum_rad;else,cmd=schedule.command_packets.q(ai,:);end
    [~,D]=pix_rhs(t,states(j,:).',cmd,model);
    P(j)=D.bus_W;tau(j,:)=D.tau_Nm;voltage(j,:)=D.bridge_voltage_V;
    power_residual(j)=D.energy_identity_residual_W;
    power_parts(j,:)=[D.bus_W D.auxiliary_W D.bridge_loss_W D.copper_W D.brake_W D.shaft_W D.friction_W D.cooling_W];
end
measured_P=P+cfg.sensor.power_std_W*randn(rs,n,1);
pq=nan(size(poses));pp=nan(size(poses,1),1);sd=pp;stationary=false(size(pp));
speed_rms=pp;window=min(.3,hold/2);
for j=1:size(poses,1)
    finish=initial+j*(move+hold);ix=sample_t>=finish-window-1e-10&sample_t<=finish+1e-10;
    if sum(ix)<max(10,round(window*80)),continue;end
    pq(j,:)=mean(qread(ix,:),1);pp(j)=mean(measured_P(ix));sd(j)=std(measured_P(ix));
    qq=qread(ix,:);stationary(j)=norm(qq(end,:)-qq(1,:))/window<.035&&max(max(qq,[],1)-min(qq,[],1))<.012;
    speed_rms(j)=sqrt(mean(sum(states(ix,5:8).^2,2)));
end
if last_t<duration-1e-9,physical_ok=false;reasons{end+1}='incomplete_probe';end
if any(P/S.voltage_V>S.maximum_source_current_A+1e-10)
    physical_ok=false;reasons{end+1}='sampled_source_current_exceeded';
end
if ~all(stationary),reasons{end+1}='one_or_more_observed_plateaus_not_stationary';end
final_energy=pix_energy(model,x);ledger=x(21:28).'-x0(21:28).';
energy=struct('initial',initial_energy,'final',final_energy,'ledger_J',ledger, ...
    'ledger_names',{{'bus','auxiliary','bridge','copper','brake','shaft','friction','cooling'}});
energy.electrical_residual_J=ledger(1)-sum(ledger(2:6))-(final_energy.magnetic_J-initial_energy.magnetic_J);
energy.mechanical_residual_J=ledger(6)-ledger(7)-(final_energy.mechanical_J-initial_energy.mechanical_J);
energy.thermal_residual_J=ledger(4)-ledger(8)-(final_energy.winding_thermal_J-initial_energy.winding_thermal_J);
energy.maximum_algebraic_residual_W=max([0;abs(power_residual)]);
energy.tolerance_J=2e-4*max(1,abs(ledger(1)));
energy.pass=all(abs([energy.electrical_residual_J energy.mechanical_residual_J energy.thermal_residual_J])<=energy.tolerance_J)&&energy.maximum_algebraic_residual_W<1e-8;
if ~energy.pass,physical_ok=false;reasons{end+1}='energy_balance_tolerance_exceeded';end
obs=struct('t',sample_t,'q',qread,'P',measured_P,'q_command',qcommand, ...
    'plateau_q',pq,'plateau_P',pp,'plateau_sd_P',sd,'stationary',stationary,'probe_id',probe.id);
issued=schedule.command_packets.issued_t<=last_t+1e-12;
obs.communication=struct('schema','bpil_observed_communication_v1', ...
    'command_issued_t',schedule.command_packets.issued_t(issued),'command_q',schedule.command_packets.q(issued,:), ...
    'encoder_packets',struct('sequence',schedule.encoder_packets.sequence(received), ...
        'sample_t',enc_t(received),'receive_t',schedule.encoder_packets.receive_t(received),'q',schedule.encoder_packets.q(received,:)), ...
    'initial_encoder_sample_t',0,'initial_encoder_receive_t',0,'initial_encoder_q',q0read, ...
    'power_record_encoder_sample_t',encoder_sample_t,'power_record_encoder_receive_t',encoder_receive_t);
truth=struct('schema','pix_truth_v1','payload',model.payload,'condition',condition,'spec',S, ...
    'seed',sensorSeed,'success',physical_ok&&all(stationary),'physical_success',physical_ok,'reasons',{unique(reasons,'stable')}, ...
    't',sample_t,'q',states(:,1:4),'dq',states(:,5:8),'tau',tau,'P',P, ...
    'current_A',states(:,9:12),'temperature_C',states(:,17:20),'bridge_voltage_V',voltage, ...
    'power_parts_W',power_parts,'power_part_names',{energy.ledger_names}, ...
    'energy',energy,'plateau_speed_rms_rad_s',speed_rms,'communication',schedule, ...
    'simulated_duration_s',last_t,'requested_duration_s',duration,'ode_rhs_calls',rhs_calls, ...
    'ode_segments',segments,'integration_error',integration_error,'scope',S.scope);
truth.initial_state_scope='Zero current and integral at prescribed initial position; no payload-aware controller preload.';
truth.audit_scope='State-domain events and sampled source-current check; no collision audit or hardware protection claim.';
    function target=reference(t)
        if t<initial,target=poses(1,:);return;end
        local=t-initial;k=min(size(poses,1),floor(local/(move+hold))+1);
        phase=local-(k-1)*(move+hold);u=max(0,min(1,phase/move));
        blend=10*u^3-15*u^4+6*u^5;
        target=poses(max(1,k-1),:)+blend*(poses(k,:)-poses(max(1,k-1),:));
    end
    function dx=rhs(t,xx)
        rhs_calls=rhs_calls+1;dx=pix_rhs(t,xx,command,model);
    end
    function [value,terminal,direction]=bounds(~,xx)
        value=[min(xx(1:4).'-model.qmin);min(model.qmax-xx(1:4).'); ...
            S.maximum_speed_rad_s-max(abs(xx(5:8)));S.max_temperature_C-max(xx(17:20)); ...
            min(1.25*S.current_limit_A-abs(xx(9:12).'))];
        terminal=ones(size(value));direction=-ones(size(value));
    end
end
