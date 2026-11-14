function obs=bpil_hefting_observation(session,cfg,probe,H)
% Causal acquisition alignment using real host time, without time warping.
% Keep all raw measurements in session; this builds estimator observations.
N=size(probe.poses,1);window=min(.3,cfg.sim.hold_s/2);
obs=struct('schema','bpil_hardware_observation_v1','probe_id',probe.id, ...
    'acquisition_valid',false,'t',zeros(0,1),'q',zeros(0,4),'P',zeros(0,1), ...
    'q_command',zeros(0,4),'plateau_q',nan(N,4),'plateau_P',nan(N,1), ...
    'plateau_sd_P',nan(N,1),'stationary',false(N,1), ...
    'plateau_windows_host_s',nan(N,2),'plateau_sample_count',zeros(N,1), ...
    'plateau_position_count',zeros(N,1),'position_age_s',zeros(0,1), ...
    'power_age_s',zeros(0,1),'power_received_t',zeros(0,1), ...
    'position_received_t',zeros(0,1),'position_sample_t',zeros(0,1), ...
    'position_sequence',zeros(0,1),'host_time_origin_s',NaN,'reasons',{{}}, ...
    'scope','Observed static plateaus from actual time; no synthetic nominal resampling or simulator truth.');
try
    assert(session.completed,'bpil:IncompleteProbe','The acquisition sequence did not complete.');
    assert(N==8&&strcmp(probe.id,'probe_02'),'bpil:Probe','The current residual model requires ordered probe_02.');
    Q=as_struct(session.raw_positions);P=as_struct(session.raw_power);C=as_struct(session.commands);
    assert(~isempty(Q)&&~isempty(P)&&~isempty(C),'bpil:Acquisition','Missing acquisition records.');
    qt=[Q.sample_t].';qr=[Q.received_t].';pt=[P.sample_t].';pr=[P.received_t].';ct=[C.sent_t].';
    assert(all(diff(qt)>0)&&all(diff(qr)>0)&&all(diff(pt)>0)&&all(diff(ct)>0), ...
        'bpil:SampleOrder','Acquisition and command timestamps must be strictly increasing.');
    assert(all(qr>=qt)&all(pr>=pt),'bpil:SampleClock','Receipt cannot precede acquisition.');
    assert(all(isfinite([qt;qr;pt;pr;ct])),'bpil:SampleClock','Nonfinite timestamp.');
    origin=session.motion_start_t;assert(isfinite(origin),'bpil:MotionClock','Missing actual motion start.');
    obs.host_time_origin_s=origin;keep=false(numel(P),1);
    q=nan(numel(P),4);command=q;qa=nan(numel(P),1);pa=qa;qreceived=qa;qsample=qa;qseq=qa;
    for k=1:numel(P)
        % A position is available at the power acquisition lower bound only
        % when it has already been received. Never use future feedback.
        j=find(qr<=pt(k)+1e-10,1,'last');h=find(ct<=pt(k)+1e-10,1,'last');
        if isempty(j)||isempty(h)||pt(k)<origin,continue,end
        qa(k)=pt(k)-qt(j);pa(k)=pr(k)-pt(k);
        if qa(k)>H.max_feedback_age_s+1e-10||pa(k)>H.max_power_age_s+1e-10,continue,end
        if isfield(Q,'valid')&&~Q(j).valid,continue,end
        if isfield(P,'valid')&&~P(k).valid,continue,end
        q(k,:)=Q(j).q;command(k,:)=C(h).q;qreceived(k)=qr(j);qsample(k)=qt(j);qseq(k)=Q(j).seq;keep(k)=true;
    end
    power=arrayfun(@(x)x.Vin_V*x.Iin_A,P).';
    assert(all(isfinite(power))&&all([P.Vin_V]>0),'bpil:Power','Invalid supply measurements.');
    obs.t=pt(keep)-origin;obs.q=q(keep,:);obs.P=power(keep);obs.q_command=command(keep,:);
    obs.position_age_s=qa(keep);obs.power_age_s=pa(keep);obs.power_received_t=pr(keep);
    obs.position_received_t=qreceived(keep);obs.position_sample_t=qsample(keep);obs.position_sequence=qseq(keep);
    assert(all(isfinite([obs.t obs.q obs.P obs.q_command]),'all'),'bpil:Alignment','Invalid aligned samples.');
    rt=[C.reference_t].';assert(all(diff(rt)>0),'bpil:ReferenceOrder','Reference steps must increase.');
    eligible=pt(keep);good=false(N,1);
    for n=1:N
        finish=cfg.sim.initial_hold_s+n*(cfg.sim.move_s+cfg.sim.hold_s);
        z=find(rt>=finish-1e-9,1);assert(~isempty(z),'bpil:IncompleteProbe','Missing pose finish command.');
        actual_finish=ct(z);start=actual_finish-window;obs.plateau_windows_host_s(n,:)=[start actual_finish];
        ix=eligible>=start-1e-10&eligible<=actual_finish+1e-10;
        obs.plateau_sample_count(n)=sum(ix);obs.plateau_position_count(n)=numel(unique(obs.position_sequence(ix)));
        if sum(ix)<max(10,ceil(window*80))||obs.plateau_position_count(n)<4,continue,end
        times=eligible(ix);
        if times(1)>start+.02||times(end)<actual_finish-.02||any(diff(times)>.03+1e-9),continue,end
        values=obs.q(ix,:);obs.plateau_q(n,:)=mean(values,1);obs.plateau_P(n)=mean(obs.P(ix));obs.plateau_sd_P(n)=std(obs.P(ix));
        obs.stationary(n)=norm(values(end,:)-values(1,:))/window<.035&& ...
            max(max(values,[],1)-min(values,[],1))<.012;
        good(n)=true;
    end
    obs.acquisition_valid=all(good);
    if ~all(good),obs.reasons{end+1}='incomplete_or_sparse_plateau_acquisition';end
    if ~all(obs.stationary),obs.reasons{end+1}='one_or_more_observed_plateaus_not_stationary';end
catch err
    obs.acquisition_valid=false;obs.reasons{end+1}=err.identifier;obs.error_message=err.message;
end
end
function A=as_struct(A)
if iscell(A),if isempty(A),A=struct([]);else,A=[A{:}];end,end
end
