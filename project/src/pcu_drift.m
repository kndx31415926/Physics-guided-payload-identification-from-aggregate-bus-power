function drift=pcu_drift(progress,scenario)
% Fixed prospective smooth, axis-dependent law; no empirical wear claim.
assert(isscalar(progress)&&isfinite(progress)&&progress>=0&&progress<=1,'pcu:Progress','Progress outside [0,1].');
t=double(progress);g=3*t^2-2*t^3;
drift=struct('holding_scale',ones(1,4),'aux_offset_W',0, ...
    'friction_scale',ones(1,4),'gain_scale',ones(1,4));
scenario=char(string(scenario));
assert(ismember(scenario,{'stationary','electrical','mechanical','combined'}),'pcu:Scenario','Unknown scenario.');
if ismember(scenario,{'electrical','combined'})
    drift.holding_scale=[1 1+.30*g.^[.8 1.2 1.6]];
    drift.aux_offset_W=.20*g^1.1;
end
if ismember(scenario,{'mechanical','combined'})
    drift.friction_scale=1+[.4 .8 .6 1].*g.^[1.3 .85 1.6 1.1];
    drift.gain_scale=1-[.08 .15 .12 .18].*g.^[.9 1.4 1.1 1.7];
end
end
