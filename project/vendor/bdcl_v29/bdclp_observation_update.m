function [obs,state,D]=bdclp_observation_update(sample,state,C)
%BDCLP_OBSERVATION_UPDATE Shared causal preprocessing for simulation and IO.
% Each valid acquired sample is assimilated once. Position differences and
% input-power filtering have identical definitions in both execution paths.
% A snapshot does not invent samples or advance their acquisition timestamps.
if nargin<2||isempty(state),state=initial_state();end
assert(isstruct(sample)&&isfield(sample,'kind'),'bdclp:ObservationSample','A sample kind is required.');
D=struct('accepted',false,'reason','','kind',sample.kind);
if strcmp(sample.kind,'snapshot')
    t=sample.t;
else
    required={'sample_t','received_t','seq','valid'};
    assert(all(isfield(sample,required)),'bdclp:ObservationSample','Sample timing, sequence and validity are required.');
    assert(isscalar(sample.sample_t)&&isfinite(sample.sample_t)&&sample.sample_t>=0&& ...
        isscalar(sample.received_t)&&isfinite(sample.received_t)&&sample.received_t>=sample.sample_t&& ...
        isscalar(sample.seq)&&isfinite(sample.seq)&&sample.seq>=0&&sample.seq==fix(sample.seq), ...
        'bdclp:ObservationTime','Acquisition must precede receipt and sequence must be a nonnegative integer.');
    t=sample.received_t;
    if ~isequal(sample.valid,true)
        D.reason='acquisition_failed';
    elseif strcmp(sample.kind,'position')
        q=sample.q;assert(isnumeric(q)&&isequal(size(q),[1 4])&&all(isfinite(q)),'bdclp:ObservationPosition','Finite four-axis position required.');
        if sample.seq<=state.position_seq || sample.sample_t<=state.sample_t
            D.reason='duplicate_or_out_of_order_position';
        else
            if isfinite(state.sample_t)
                interval=sample.sample_t-state.sample_t;
                raw=(q-state.q)/interval;
                a=exp(-interval/C.observation.velocity_filter_tau_s);
                state.dq=a*state.dq+(1-a)*raw;
                state.velocity_valid=interval<=C.control.max_velocity_gap_s;
            else
                state.dq=zeros(1,4);state.velocity_valid=false;
            end
            state.q=double(q);state.sample_t=sample.sample_t;
            state.position_received_t=sample.received_t;state.position_seq=sample.seq;
            state.sample_time_exact=isfield(sample,'sample_time_exact')&&isequal(sample.sample_time_exact,true);
            if isfield(sample,'sample_time_window_s')
                state.sample_time_window_s=sample.sample_time_window_s;
            else
                state.sample_time_window_s=[sample.sample_t sample.received_t];
            end
            D.accepted=true;
        end
    elseif strcmp(sample.kind,'power')
        assert(all(isfield(sample,{'Vin_V','Iin_A'}))&&isscalar(sample.Vin_V)&& ...
            isfinite(sample.Vin_V)&&sample.Vin_V>0&&isscalar(sample.Iin_A)&&isfinite(sample.Iin_A), ...
            'bdclp:ObservationPower','Finite calibrated input voltage/current samples required.');
        if sample.seq<=state.power_seq || sample.sample_t<=state.power_sample_t
            D.reason='duplicate_or_out_of_order_power';
        else
            Pin=sample.Vin_V*sample.Iin_A;
            if isfinite(state.power_sample_t)
                interval=sample.sample_t-state.power_sample_t;
                a=exp(-interval/C.power.filter_tau_s);
                state.Pavg_W=a*state.Pavg_W+(1-a)*max(Pin,0);
            else
                state.Pavg_W=max(Pin,0);
            end
            state.Pin_W=Pin;state.Vin_V=sample.Vin_V;state.Iin_A=sample.Iin_A;
            state.power_sample_t=sample.sample_t;state.power_received_t=sample.received_t;
            state.power_seq=sample.seq;D.accepted=true;
        end
    else
        error('bdclp:ObservationKind','Unknown sample kind.');
    end
end
assert(isscalar(t)&&isfinite(t)&&t>=0,'bdclp:ObservationTime','Nonnegative monotonic snapshot time required.');
obs=struct('t',t,'q',state.q,'dq',state.dq,'sample_t',state.sample_t, ...
    'power_sample_t',state.power_sample_t,'position_received_t',state.position_received_t, ...
    'power_received_t',state.power_received_t,'Pin_W',state.Pin_W,'Pdraw_W',max(state.Pin_W,0), ...
    'Vin_V',state.Vin_V,'Iin_A',state.Iin_A,'Pavg_W',state.Pavg_W, ...
    'position_sequence',state.position_seq,'power_sequence',state.power_seq, ...
    'sample_time_exact',state.sample_time_exact,'sample_time_window_s',state.sample_time_window_s, ...
    'position_time_semantics','sample_t_is_conservative_acquisition_lower_bound_unless_exact_flag_true', ...
    'position_age_s',t-state.sample_t,'power_age_s',t-state.power_sample_t, ...
    'velocity_valid',state.velocity_valid);
obs.position_fresh=isfinite(state.sample_t)&&state.position_received_t<=t+1e-12&& ...
    obs.position_age_s>=-1e-12&&obs.position_age_s<=C.control.max_position_age_s+1e-12;
obs.power_valid=isfinite(state.power_sample_t)&&state.power_received_t<=t+1e-12&& ...
    obs.power_age_s>=-1e-12&&obs.power_age_s<=C.control.max_power_age_s+1e-12;
obs.usable_for_control=obs.position_fresh&&obs.power_valid&&obs.velocity_valid;
if isfield(sample,'last_cmd')
    obs.command_q=sample.last_cmd.q;
    obs.command_age_s=max(0,t-sample.last_cmd.issued_t);
end
end
function S=initial_state()
S=struct('q',nan(1,4),'dq',zeros(1,4),'sample_t',NaN,'power_sample_t',NaN, ...
    'position_received_t',NaN,'power_received_t',NaN,'position_seq',-1,'power_seq',-1, ...
    'sample_time_exact',false,'sample_time_window_s',[NaN NaN], ...
    'velocity_valid',false,'Pin_W',NaN,'Vin_V',NaN,'Iin_A',NaN,'Pavg_W',NaN);
end
