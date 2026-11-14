function out=prc_observation(obs,cfg)
%PRC_OBSERVATION Encoder-only features for an eight-pose planar Lao transfer.
% Reads t, q, q_command, and (when present) stationary only. Extra fields,
% payload labels and simulator truth do not affect any returned value.
% state(pose,joint,:) = [q, q_command-q, positive_direction, negative_direction].
out=struct('state',nan(8,4,4),'usable',false,'reasons',{{}}, ...
    'plateau_samples',zeros(8,1),'stationary',false(8,1), ...
    'direction_delta_rad',nan(8,4),'direction_unknown',true(8,4), ...
    'initial_direction_no_motion',true,'plateau_window_s',.3, ...
    'direction_window_s',.1,'direction_deadband_rad',NaN, ...
    'scope','Planar eight-pose transfer; measured encoders and issued commands only.');
required={'t','q','q_command'};
if ~isstruct(obs)||~isscalar(obs)||~all(isfield(obs,required))
    out.reasons={'missing_encoder_or_command_observations'};return
end
t=double(obs.t(:));q=double(obs.q);command=double(obs.q_command);n=numel(t);
if n<2||~isequal(size(q),[n 4])||~isequal(size(command),[n 4])|| ...
        ~isreal(t)||~isreal(q)||~isreal(command)||~all(isfinite(t))||any(diff(t)<=0)
    out.reasons={'invalid_observation_shape_or_time'};return
end
quantum=2*pi/4096;
if isfield(cfg,'legacy')&&isfield(cfg.legacy,'observation')&&isfield(cfg.legacy.observation,'position_quantum_rad')
    quantum=cfg.legacy.observation.position_quantum_rad;
end
assert(isscalar(quantum)&&isfinite(quantum)&&quantum>=0,'prc:Quantum','Invalid encoder quantum.');
out.direction_deadband_rad=quantum;
reported=true(8,1);
if isfield(obs,'stationary')
    st=obs.stationary;
    if numel(st)~=8||~isreal(st),out.reasons={'invalid_stationarity_shape'};return,end
    reported=isfinite(st(:))&st(:)==1;
end
cycle=cfg.sim.move_s+cfg.sim.hold_s;direction_ok=true(8,1);
for p=1:8
    start=cfg.sim.initial_hold_s+(p-1)*cycle;finish=start+cycle;
    plateau=t>=finish-.3-1e-10&t<=finish+1e-10;
    out.plateau_samples(p)=sum(plateau);
    if sum(plateau)<10||~all(isfinite(q(plateau,:)),'all')||~all(isfinite(command(plateau,:)),'all')
        out.reasons{end+1}=sprintf('invalid_plateau_%d',p);continue
    end
    qp=q(plateau,:);cp=command(plateau,:);
    out.state(p,:,1)=mean(qp,1);out.state(p,:,2)=mean(cp-qp,1);
    out.stationary(p)=reported(p)&&norm(qp(end,:)-qp(1,:))/.3<.035&& ...
        max(max(qp,[],1)-min(qp,[],1))<.012;
    if p==1
        % The first pose is also the initial pose: no approach motion exists.
        delta=zeros(1,4);
    else
        move_end=start+cfg.sim.move_s;
        early=t>=start-1e-10&t<=start+.1+1e-10;
        late=t>=move_end-.1-1e-10&t<=move_end+1e-10;
        if ~any(early)||~any(late)||~all(isfinite(q(early,:)),'all')||~all(isfinite(q(late,:)),'all')
            direction_ok(p)=false;out.reasons{end+1}=sprintf('missing_approach_direction_%d',p);continue
        end
        delta=median(q(late,:),1)-median(q(early,:),1);
    end
    positive=delta>quantum;negative=delta<-quantum;
    out.direction_delta_rad(p,:)=delta;out.direction_unknown(p,:)=~positive&~negative;
    out.state(p,:,3)=positive;out.state(p,:,4)=negative;
end
if ~all(out.stationary),out.reasons{end+1}='one_or_more_plateaus_not_stationary';end
out.usable=all(out.stationary)&&all(direction_ok)&&all(isfinite(out.state),'all');
out.reasons=unique(out.reasons,'stable');
end
