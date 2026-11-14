function S = bpil_communication_schedule(spec,seed,dt,steps,command_stride)
%BPIL_COMMUNICATION_SCHEDULE Independent, auditable packet-delay draws.
% This helper is used only by the opt-in communication simulation. Delays
% are one-way; they do not extend the fixed host issue/sample period.
required={'command_delay_s','encoder_delay_s'};
assert(isstruct(spec)&&isscalar(spec),'bpil:Communication','Communication specification must be a scalar struct.');
for j=1:numel(required)
    name=required{j};
    assert(isfield(spec,name),'bpil:Communication','Missing %s.',name);
    bounds=spec.(name);
    assert(isnumeric(bounds)&&isreal(bounds)&&numel(bounds)==2&&all(isfinite(bounds(:)))&& ...
        bounds(1)>=0&&bounds(2)>=bounds(1),'bpil:Communication','%s must be finite [minimum maximum] seconds.',name);
    % One pending packet per channel is sufficient only below one period.
    assert(ceil(bounds(2)/dt-1e-12)<command_stride,'bpil:Communication', ...
        '%s rounded to the plant grid must be shorter than the 50 ms packet period.',name);
end
if isfield(spec,'seed'),seed=spec.seed;end
assert(isnumeric(seed)&&isreal(seed)&&isscalar(seed)&&isfinite(seed)&&seed>=0&&seed==floor(seed)&&seed<2^32, ...
    'bpil:Communication','Communication seed must be an integer in [0,2^32-1].');
command_seed=mod(double(seed)+104729,2^32);
encoder_seed=mod(double(seed)+130363,2^32);
command_stream=RandStream('mt19937ar','Seed',command_seed);
encoder_stream=RandStream('mt19937ar','Seed',encoder_seed);
nc=ceil(steps/command_stride);ne=floor(steps/command_stride);
command_requested=draw_delay(command_stream,spec.command_delay_s,nc);
encoder_requested=draw_delay(encoder_stream,spec.encoder_delay_s,ne);
command_steps=ceil(command_requested/dt-1e-12);
encoder_steps=ceil(encoder_requested/dt-1e-12);
command_t=(0:nc-1)'*command_stride*dt;
encoder_t=(1:ne)'*command_stride*dt;
S=struct('schema','bpil_communication_timing_v1','spec',spec,'base_seed',seed, ...
    'command_rng_seed',command_seed,'encoder_rng_seed',encoder_seed, ...
    'rng_algorithm','mt19937ar; independent local stream per channel', ...
    'delay_grid_rule','ceil(requested_delay / 0.001 s); fixed 12.5 ms applies at 13 ms', ...
    'command_period_s',command_stride*dt,'encoder_sample_period_s',command_stride*dt, ...
    'power_sample_period_s',.010,'power_transport_delay_s',0, ...
    'initial_encoder_cache','sample and arrival at t=0; preflight cache available before first command', ...
    'command_delay_steps',command_steps,'encoder_delay_steps',encoder_steps);
S.command_packets=struct('sequence',(1:nc)','issued_t',command_t, ...
    'requested_delay_s',command_requested,'applied_delay_s',command_steps*dt, ...
    'scheduled_apply_t',command_t+command_steps*dt,'applied_t',nan(nc,1),'q',nan(nc,4));
S.encoder_packets=struct('sequence',(1:ne)','sample_t',encoder_t, ...
    'requested_delay_s',encoder_requested,'applied_delay_s',encoder_steps*dt, ...
    'scheduled_receive_t',encoder_t+encoder_steps*dt,'receive_t',nan(ne,1),'q',nan(ne,4));
end
function values=draw_delay(stream,bounds,n)
values=bounds(1)+(bounds(2)-bounds(1))*rand(stream,n,1);
end
