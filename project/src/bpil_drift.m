function drift=bpil_drift(block,nblocks,kind)
% Scenario parameters, not measurements or a calibrated physical wear law.
t=(block-1)/max(1,nblocks-1);
if nargin<3,kind='common';end
switch kind
    case 'common',holding=[1,1+.30*t,1+.30*t,1+.30*t];
    case 'asymmetric',holding=[1,1+.30*t,1+.05*t,1+.60*t];
    otherwise,error('bpil:DriftKind','Unknown modeled drift kind');
end
drift=struct('holding_scale',holding, ...
    'aux_offset_W',.20*t,'friction_scale',1+.60*t,'gain_scale',1-.15*t);
end
