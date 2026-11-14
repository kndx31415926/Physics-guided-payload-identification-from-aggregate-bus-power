function drift=pra_drift(progress,scenario)
%PRA_DRIFT Prespecified quasi-stationary accelerated drift, not a wear law.
% Parameters are fixed within an episode and change between episodes only.
assert(isnumeric(progress)&&isscalar(progress)&&isreal(progress)&&isfinite(progress)&&progress>=0&&progress<=1, ...
    'pra:Progress','Progress must be a finite scalar in [0,1].');
scenario=char(string(scenario));t=double(progress);
drift=struct('holding_scale',ones(1,4),'aux_offset_W',0, ...
    'friction_scale',ones(1,4),'gain_scale',ones(1,4));
switch scenario
    case 'stationary'
    case 'electrical'
        drift.holding_scale=[1,1+.30*t,1+.30*t,1+.30*t];drift.aux_offset_W=.20*t;
    case 'mechanical'
        drift.friction_scale=1+t*[.4 .8 .6 1.0];drift.gain_scale=1-t*[.08 .15 .12 .18];
    case 'combined'
        drift.holding_scale=[1,1+.30*t,1+.30*t,1+.30*t];drift.aux_offset_W=.20*t;
        drift.friction_scale=1+t*[.4 .8 .6 1.0];drift.gain_scale=1-t*[.08 .15 .12 .18];
    otherwise
        error('pra:Scenario','Unknown drift scenario: %s',scenario);
end
end
